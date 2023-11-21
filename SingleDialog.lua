-- Photo Classification Dialog for CrossPrism Lightroom Plugin
--

-- Access the Lightroom SDK namespaces.
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrHttp = import 'LrHttp'
local LrLogger = import 'LrLogger'
local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPhotoInfo = import 'LrPhotoInfo'
local prefs = import 'LrPrefs'.prefsForPlugin()
local LrErrors = import 'LrErrors'

local utils = require 'utils.lua'
local mime = require 'mime.lua'

local log = LrLogger( 'ClassificationDialog' )
local logging_method = "print"

local floatingWillClose = false
local thumbnail_request = nil
local loadedTrees = {}
local selectedPhoto = nil
local photoRowCount = 10

log:enable( { fatal = logging_method,
              error = logging_method,
              warn = logging_method,
              info = logging_method,
              debug = logging_method,
              trace = logging_method,
} )

local JSON = require 'JSON.lua'
local scientific_choice_menu = {
   {
      title = "Common",
      value = "name_common"
   },
   {
      title = "Taxonomy",
      value = "name_taxonomy"
   },
   {
      title = "All",
      value = "name_all"
   },
   
}

local function showCustomDialog()
   local baseUrl = prefs.server_url
	LrFunctionContext.postAsyncTaskWithContext( "ClassificationDialog", function( context )
	    local f = LrView.osFactory()
        local trainers = {}

	    -- Create a bindable table.  Whenever a field in this table changes
	    -- then notifications will be sent.
	    local props = LrBinding.makePropertyTable( context )
        props.bulk_process_title = "process xxxxxx photos"
        props.bulk_process_visible = false
        props.bulk_status_text = ""
        props.timeout = utils.defaultNumber(prefs.timeout,60)
        props.training_checkboxes_visible = true
        props.training_labels_visible = true
        props.labels = ""
        props.filter_labels = utils.default(prefs.filter_labels,"")
        props.filter_training = utils.default(prefs.filter_training,"")
        props.image = nil
        props.existing = nil
        props.training_labels = nil
        props.photo_name = ""
        props.photo_width = 128
        props.photo_height = 128
        props.trees = {}
        props.subtrees = {}
        props.treeid = utils.default(prefs.singleclassify_treeid,nil)
        props.subtreeid = utils.default(prefs.singleclassify_subtreeid,'-')
        props.sendHints = prefs.send_hints
        props.saliency = false
        props.highest_only = false
        props.trainers = {}
        props.trainerid = nil
        props.trainer_existing_labels = nil
        props.trainer_existing_table = {}
        props.keywords = {}
        props.values = ''
        props.value_items = {}
        props.current_value_item = ''
        props.selected_value_item = {}
        props.value_lines = 0
        props.value_height = 100
        props.parent_keyword_id = utils.default(prefs.parent_keyword_id,"crossprism")
        props.scientific_name = utils.default(prefs.scientific_name,"name_common")
              
        props.useTitle = utils.default(prefs.use_title,false)
        props.useDescription = utils.default(prefs.use_description,false)
        props.useKeywords = utils.default(prefs.use_keywords,true)
        props.useExclude = utils.default(prefs.use_exclude,false)
        props.useParent = utils.default(prefs.use_parent,true)
        props.title = ""
        props.description = ""
        
        local processSelected
        local firstUpdateSent = false
        local bulkProcessing = false
        local bulkCancel = false
        local bulkCountdown = 0
        
        if prefs.highest_only ~= nil then
           props.highest_only = prefs.highest_only
        end
        props = utils.initCheckboxLabels(props)


        local function updateBulkButton()
           if bulkProcessing then
              props.bulk_process_title = "Cancel"
              props.bulk_process_visible = true
           else
              local catalog = LrApplication.activeCatalog()
              local targets = catalog:getTargetPhotos()
              if #targets > 1 then
                 props.bulk_process_title = "Process " .. #targets .. " photos"
                 props.bulk_process_visible = true
              else
                 props.bulk_process_visible = false
                 props.bulk_status_text = ""
              end
           end
        end
        
        local function updateSelectedPhoto()
           LrTasks.startAsyncTask(function()
                 local catalog = LrApplication.activeCatalog()
                 local photo = catalog:getTargetPhoto()
                 if photo ~= nil then
                    processSelected(photo)
                 end
           end)
        end
        
        props:addObserver('treeid',function(propTable,key,value)
                             log:trace("in treeid observer")
                             props.subtrees = utils.prepSubtrees(loadedTrees[value])
                             props.subtreeid = '-'
                             if firstUpdateSent then
                                updateSelectedPhoto()
                             end
                             firstUpdateSent = true
        end)

        props:addObserver('subtreeid',function(propTable,key,value)
                             log:trace("in subtreeid observer")
                             updateSelectedPhoto()
        end)

        props:addObserver('trainerid',function(propTable,key,value)
                             props = utils.trainerChange(trainers,value,props)
        end)

        props:addObserver('selected_value_item',function(propTable,key,value)
                             if value ~= nil then
                                if #value > 0 then
                                   props.current_value_item = value[1]
                                else
                                   props.current_value_item = ''
                                end
                             end
        end)
        
        props:addObserver('saliency',function(propTable,key,value)
                             updateSelectedPhoto()
        end)

        local function fetchTrees()
           LrTasks.startAsyncTask(function()
                 treeResults = utils.loadTrees(baseUrl)
                 if treeResults ~= nil then
                    loadedTrees = treeResults[1]
                    props.trees = utils.prepTrees(treeResults[2])
                    table.sort(props.trees)
                    if (props.treeid == nil) or (loadedTrees[props.treeid] == nil) then
                       props.treeid = "default"
                    elseif loadedTrees[props.treeid] ~= nil then
                       props.subtrees = utils.prepSubtrees(loadedTrees[props.treeid])
                    end
                 end
           end)
        end

        local function fetchTrainers()
           LrTasks.startAsyncTask(function()
                 trainersResult = utils.loadTrainers(baseUrl, false)
                 if trainersResult ~= nil then
                    trainers = trainersResult[1]
                    keyset = trainersResult[2]
                    if keyset ~= nil then
                       props.trainers = utils.prepTrainers(keyset)
                       if props.trainerid == nil and #keyset > 0 then
                          props.trainerid = keyset[1]
                       end
                    end
                 end
           end)
        end


        local function train()
           LrTasks.startAsyncTask(function()
                 labels = props.training_labels
                 multilabels = utils.getCheckmarkLabels(props)
                 
                 labels = utils.filterExisting(labels,props.filter_training)
                 multilabels = utils.filterExisting(multilabels,props.filter_training)
                 labels = utils.mergeCSV(labels,multilabels)
                 
                 local photos = { selectedPhoto }
                 log:tracef( "target Photos: %d", #photos )
                 log:tracef("labels: %s",labels)
                 local images = {}
                 for _,photo in pairs(photos) do
                    log:trace( "requesting jpeg thumbnail..." )
                    local thumbSize = utils.maxDimUsingShortSide(photo,512)
                    photo:requestJpegThumbnail(thumbSize,thumbSize,function(jpeg,reason)
                                                  log:trace( " got train jpeg" )
                                                  images[#images+1] = {
                                                     name = photo:getFormattedMetadata("fileName"),
                                                     image = jpeg,
                                                     labels = labels
                                                  }
                    end)
                 end
                 utils.postTrain(baseUrl,props.trainerid,images)
           end)
        end
        


        local function formatItems(scores,values)
           local retItems = {}
           for label,score in pairs(values) do
              if label ~= "pos" then
                 if (type(score) == "table") then
                    if #score > 0 then
                       score = table.concat(score,",")
                    else
                       score = ''
                    end
                    retItems[#retItems+1] = string.format("%s : %s",label,score)
                 else
                    retItems[#retItems + 1] = string.format("%s : %.2f",label,score)
                 end
              end
           end
           if scores ~= nil then
              retItems[#retItems+1] =  "- Labels -"
              local sortedScores = utils.sortTableByValue(scores)
              for i,p in ipairs(sortedScores) do
                 retItems[#retItems + 1] =  string.format("%s : %.2f",p[1],p[2])
              end
           end

           -- Make it into a simple list compatible table
           local listItems = {}
           for k,v in ipairs(retItems) do
              listItems[#listItems + 1] = { title = v, value = v }
           end
           return listItems
        end
        local function formatScores(scores,values)
           local temp = formatItems(scores,values)
           local retString = ""
           for i,v in ipairs(temp) do
              retString = retString .. v['title'] .. "\n"
           end
           return #temp,retString
        end

        local function filterTopLabels(scores)
           local sortedScores = utils.sortTableByValue(scores)
           local prevScore = nil
           local retItems = {}
           
           for i,p in ipairs(sortedScores) do
              if i > 1 and math.abs(p[2] - prevScore) > 1e-8 then
                 break
              end
              prevScore = p[2]
              retItems[#retItems + 1] =  p[1]              
           end
           return retItems
        end

        local function sortTopLabels(scores)
           local sortedScores = utils.sortTableByValue(scores)
           local retItems = {}
           
           for i,p in ipairs(sortedScores) do
              retItems[#retItems + 1] =  p[1]              
           end
           return retItems
        end

        local function tic(delay)
           if delay == nil then
              delay = 0
           end
           local now = os.time()
           local ellapsed = 0
           while (ellapsed <= delay) do
              if bulkCancel then
                 props.bulk_status_text = "Cancelling..."
                 LrErrors.throwCanceled()
              end
              LrTasks.yield()
              if delay > 0 then
                 -- log:trace("delaying...")
                 LrTasks.sleep(0.1)
                 ellapsed = ellapsed + os.time() - now
              else
                 ellapsed = 1
              end
           end
        end

        function processSelected(photo, blockingClassify)
           props.labels = "...."
           props.title = ""
           props.description = ""
           props.value_items = {}
           props.labels_enabled = false

           local existing = photo:getFormattedMetadata("keywordTags")
           log:tracef( "Existing keywords: %s",existing )
           props.existing = existing
           props.training_labels = utils.filterExisting(existing,props.filter_training)
           props = utils.updateCheckboxLabels(props)
           log:tracef( "photo name: %s", props.photo_name )
           selectedPhoto = photo

           local thumbnail_request = nil
           local running = 0
           
           local function thumbnailCallback(jpeg,reason)
              log:tracef( "Got thumbnail" )
              props.labels = "Classifying..."
              local headers = {
                 { field = 'Content-Type', value = "image/jpeg" }
              }
              if props.treeid ~= nil and props.treeid ~= "" then
                 local treepath = props.treeid
                 log:tracef("tree: %s subtree:%s", props.treeid, props.subtreeid)
                 if props.subtreeid ~= '-' then
                    treepath = treepath.."/"..props.subtreeid
                 end
                 headers[#headers+1] = { field = 'X-Classifier-Tree', value = treepath }
              end
              headers[#headers+1] = { field = "X-Classifier-Photo", value = photo.localIdentifier}
              if props.sendHints then
                 headers[#headers+1] = { field = 'X-Classifier-Labels', value = props.existing }
              end
              photoOptions = "classify"
              if props.saliency then
                 photoOptions = photoOptions .. ",saliency"
              end
              photoOptions = photoOptions .. "," .. props.scientific_name
              
              log:tracef("photoOptions: %s",photoOptions)
              headers[#headers+1] = { field = 'X-Classifier-Options', value = photoOptions }

              classifyFunc = function()
                    local result, hdrs = LrHttp.post( baseUrl .. "/classify", jpeg, headers, "POST", props.timeout )
                    log:tracef( "response: [%s]", result )
                    if result ~= nil then
                       local lua_value = JSON:decode(result)
                       local matchesSelected
                       if lua_value ~= nil then
                          if not blockingClassify then
                             local catalog = LrApplication.activeCatalog()
                             local selected = catalog:getTargetPhoto()
                             matchesSelected = lua_value['photoid'] == nil or (selected ~= nil and lua_value['photoid'] == selected.localIdentifier)
                          else
                             matchesSelected = true
                          end
                          
                          if matchesSelected then
                             local values = lua_value['values']
                             local scores = lua_value['scores']
                             local roles = lua_value['roles']
                             
                             props.title = ''
                             props.description = ''
                             
                             if roles ~= nil then
                                for text,pos in pairs(roles) do
                                   if utils.tableContains(pos,"title") then
                                      scores[text] = nil
                                      props.title = text
                                      if props.description == '' then
                                         props.description = text
                                      end
                                   elseif utils.tableContains(pos,"description") then
                                         scores[text] = nil
                                         props.description = text
                                         if props.title == '' then
                                            props.title = text
                                         end
                                   end
                                end
                             end

                             if props.highest_only then
                                lastLabel = filterTopLabels(scores)
                             else
                                lastLabel = sortTopLabels(scores)
                             end

                             if props.useExclude then
                                props.labels = utils.filterExisting(table.concat(lastLabel, ","), props.filter_labels)
                             else
                                props.labels = table.concat(lastLabel,",")
                             end
                             props.labels_enabled = true
                             log:tracef("labels: %s",props.labels)

                             local count,formattedValues = formatScores(scores,values)
                             props.values = formattedValues
                             props.value_items = formatItems(scores,values)
                             props.current_value_item = ''
                             props.value_lines = count
                             props.value_height = count * 12
                             log:tracef("values: %s",props.values)
                             log:tracef("value lines: %d",props.value_lines)
                          end
                       end
                    else
                       props.labels = "Error communicating with CrossPrism"
                    end
                    thumbnail_request = nil
                    running = running - 1
                    log:tracef("clearing thumbnail request %d",running)
              end

              LrTasks.startAsyncTask(classifyFunc)

           end

           log:trace("sending thumbnail request")
           running = running + 1
           if props.saliency then
              thumbSize = 4096
           else
              thumbSize = utils.maxDimUsingShortSide(photo, 512)
           end
           props.labels = "Creating thumbnail..."
           thumbnail_request = photo:requestJpegThumbnail(thumbSize,thumbSize, thumbnailCallback)
           

           while running > 0 do
              log:tracef("waiting for thumbnail request...%d",running)
              tic(0.5)
           end
        end

        local function checkSelectedPhoto()
           local catalog = LrApplication.activeCatalog()
           local selected = catalog:getTargetPhoto()
           log:trace( " *** got target photo ***" )
           if selected ~= nil then
              --props["photo"] = selected
              --props["photo_background"] = LrColor(0.0,0.0,0.0)
              --props["photo_name"] = selected:getFormattedMetadata("fileName")
              log:tracef("processing name: %s",props.photo_name)
              processSelected(selected)
           end
        end

        local function updateView(photo)
           props["photo"] = photo
           props["photo_background"] = LrColor(0.0,0.0,0.0)
           props["photo_name"] = photo:getFormattedMetadata("fileName")
        end
        
        local function updateContents()
           if bulkProcessing then
              return
           end
           local catalog = LrApplication.activeCatalog()
           local selected = catalog:getTargetPhoto()
           if selected ~= nil then
              updateView(selected)
           end
           LrFunctionContext.postAsyncTaskWithContext("updateContents",
                                                      function(context)
                                                         context:addFailureHandler(function(status,msg)
                          log:errorf("Failed during update contents: %s",msg)
                                                         end)                                                                 
                                                         checkSelectedPhoto()
           end)
        end

        local function setSelection(photo)
           if photo ~= nil then
              local catalog = LrApplication.activeCatalog()
              local targetPhotos = catalog:getTargetPhotos()
              local selection = {}
              if #targetPhotos > 1 then
                 selection = targetPhotos
              end
              catalog:setSelectedPhotos(photo,selection)
           end
        end
        
        local function setPhotoIndex(catalog,photos,index)           
           if index > #photos then
              index = index % #photos
           end
           if index < 1 then
              index = #photos + index
           end

           local targetPhotos = catalog:getTargetPhotos()
           local selection = {}
           if #targetPhotos > 1 then
              selection = targetPhotos
           end
           catalog:setSelectedPhotos(photos[index],selection)
        end

        local function advanceSelectedPhoto(offset)
           LrTasks.startAsyncTask(function()
                 local catalog = LrApplication.activeCatalog()
                 local photos = catalog:getMultipleSelectedOrAllPhotos()
                 for i,photo in pairs(photos) do
                    if photo == selectedPhoto then
                       setPhotoIndex(catalog,photos,i + offset)
                       break
                    end
                 end
           end
           )
        end

        local function applyKeywords(photo)
           local filter = nil
           local parent = nil
           local labels = nil
           local title = nil
           local description = nil
           if props.useKeywords then
              labels = props.labels
              if props.useExclude then
                 filter = props.filter_labels
              end
              if props.useParent then
                 parent = props.parent_keyword_id
              end
           end
           if props.useTitle then
              title = props.title
           end
           if props.useDescription then
              description = props.description
           end
           utils.addMetadata(photo, labels, filter, parent, title, description)
        end

        local function bulkProcess()
           if LrDialogs.confirm("Auto process selected photos?") == "ok" then
              local bulkFunc = function(context)
                 local catalog = LrApplication.activeCatalog()
                 local photos = catalog:getTargetPhotos()
                 bulkCountdown = #photos
                 bulkProcessing = true
                 bulkCancel = false
                 updateBulkButton()
                 context:addCleanupHandler(function()
                       bulkProcessing = false
                       updateBulkButton()
                 end)
                 context:addFailureHandler(function(status,msg)
                       log:errorf("Failed during bulk processing: %s",msg)
                       if LrErrors.isCanceledError(msg) then
                          props.bulk_status_text = "Cancelled"
                       end
                 end)
                 props.bulk_status_text = string.format("%d remaining",#photos)
                 local processed = 0
                 local lastProcessed = nil
                 for i,photo in ipairs(photos) do
                    lastProcessed = photo
                    updateView(photo)
                    processSelected(photo,true)
                    log:tracef("Processed photo %d",i)
                    -- log:tracef("labels during bulk: %s", props.labels)
                    if props.labels_enabled then
                       applyKeywords(photo)
                    end
                    props.bulk_status_text = string.format("%d remaining",#photos - i)
                    processed = processed + 1
                    if bulkCancel then
                       log:trace("Cancelling...")
                       break
                    end
                 end
                 props.bulk_status_text = string.format("%d processed",processed)
                 setSelection(lastProcessed)
              end
              LrFunctionContext.postAsyncTaskWithContext( "bulkProcess", bulkFunc)
           end
        end
	    -- Create the contents for the dialog.
        local photo_column = f:column {
           f:row {
              fill_horizontal = 1.0,
              f:static_text {
                 title = LrView.bind( "photo_name" ),
              }
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 place_horizontal = 0.33,
                 f:catalog_photo {                    
                    photo = LrView.bind( "photo" ),
                    width = 128,
                    height = 128,
                    frame_width = 2,
                    frame_color = LrView.bind("photo_framecolor"),
                 },
              }
           },
           f:row {
              fill_horizontal = 1.0,
              f:push_button {
                 place_horizontal = 0.33,
                 title = "<",
                 action = function(button)
                    advanceSelectedPhoto(-1)
                 end
              },
              f:push_button {
                 title = ">",
                 action = function(button)
                    advanceSelectedPhoto(1)
                 end
              },
           },
           f:group_box {                 
              title = "Scores",
              f:edit_field {
                 height = 36,
                 width = 150,
                 value = LrView.bind("current_value_item"),
                 height_in_lines = 1
              },
              --f:edit_field {
              f:simple_list {
                 height = 200,
                 width = 150,
                 items = LrView.bind("value_items"),
                 value = LrView.bind("selected_value_item"),
                 --height_in_lines = LrView.bind("value_lines")
              }
           },
        }

        photo_column.spacing = 0

        local training_label_rows = f:column(utils.initCheckboxRows(props))

	    local c = f:row {
           margin = 10,
           width = 640,
           height = 500,
           place = "horizontal",
           -- Bind the table to the view.  This enables controls to be bound
		    -- to the named field of the 'props' table.
		    
           bind_to_object = props,
           photo_column,
           f:column {
              f:row {
                 fill_horizontal = 1.0,
                 f:column {
                    fill_horizontal = 1.0,
                    f:group_box {
                       fill_horizontal = 1.0,
                       title = "Keywords",
                       f:row {
                          fill_horizontal = 1.0,
                          place_vertical = 0.0,
                          f:static_text {
                             title = "Domain: "
                          },
                          f:popup_menu {
                             value = LrView.bind( "treeid" ),
                             items = LrView.bind( "trees" )
                          },
                          f:popup_menu {
                             value = LrView.bind( "subtreeid" ),
                             items = LrView.bind( "subtrees" )
                          },
                          f:push_button {
                             title = "Reload",
                             action = function()
                                fetchTrees()
                                fetchTrainers()
                             end
                          }
                       },
                       f:row {
                          f:checkbox {
                             title = "Send existing keywords as hints",
                             value = LrView.bind("sendHints")
                          },
                          f:checkbox {
                             title = "Only use highest scoring label",
                             value = LrView.bind("highest_only")
                          }                             
                       },
                       f:row {
                          f:checkbox {
                             title = "Focus Crop",
                             value = LrView.bind("saliency")
                          },
                          f:spacer {
                             width = 10
                          },
                          f:static_text {
                             title = "Species Names:"
                          },
                          f:popup_menu {
                             value = LrView.bind("scientific_name"),
                             items = scientific_choice_menu
                          }
                       },
                       f:row {
                          f:checkbox {
                             title = "Keywords: ",
                             value = LrView.bind("useKeywords")
                          },
                          f:edit_field {
                             fill_horizontal = 1.0,
                             height_in_lines = 6,
                             placeholder_string = "no keywords",
                             value = LrView.bind( "labels" ),
                             enabled = LrView.bind( "labels_enabled" ),
                             auto_completion = true,
                             completion = LrView.bind( "keywords" )
                          },
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:checkbox {
                             title = "Exclude: ",
                             value = LrView.bind("useExclude")                             
                          },
                          f:edit_field {
                             fill_horizontal = 1.0,
                             placeholder_string = "keywords to exclude from apply",
                             value = LrView.bind( "filter_labels" ),
                             enabled = true
                          }
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:checkbox {
                             title = "Parent Keyword:",
                             value = LrView.bind("useParent")
                          },
                          f:edit_field {
                             placeholder_string = "parent keyword",
                             value = LrView.bind( "parent_keyword_id" ),
                             enabled = true
                          },
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:checkbox {
                             title = "Title: ",
                             value = LrView.bind("useTitle")
                          },
                          f:edit_field {
                             fill_horizontal = 1.0,
                             placeholder_string = "",
                             value = LrView.bind( "title" ),
                             enabled = true
                          },
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:checkbox {                             
                             title = "Description: ",
                             value = LrView.bind("useDescription")
                          },
                          f:edit_field {
                             fill_horizontal = 1.0,
                             value = LrView.bind("description"),
                             enabled = true
                          }                          

                       },

                       f:row {
                          fill_horizontal = 1.0,
                          f:column {
                             place = "horizontal",
                             f:push_button {
                                title = LrView.bind("bulk_process_title"),
                                --visible = true,
                                visible = LrView.bind("bulk_process_visible"),
                                action = function()
                                   if bulkProcessing then
                                      bulkCancel = true
                                   else
                                      bulkProcess()
                                   end
                                end
                             },
                             f:static_text {
                                title = LrView.bind("bulk_status_text"),
                                width_in_chars = 20,
                                truncation = "middle"
                             }
                          },
                          f:column {
                             place = "horizontal",
                             place_horizontal = 1.0,
                             f:push_button {
                                title = "Reload",
                                action = function()
                                   LrTasks.startAsyncTask(function()
                                         checkSelectedPhoto()
                                   end)
                                end                   
                             },
                             f:push_button {
                                title = "Apply",
                                action = function()
                                   if props.labels_enabled then
                                      applyKeywords(selectedPhoto)
                                   end
                                end
                             }
                          }
                       }
                    },
                    f:spacer {
                       height = 12
                    },
                    f:group_box {
                       title = "Train",
                       
                       fill_horizontal = 1.0,
                       f:popup_menu {
                          value = LrView.bind( "trainerid" ),
                          items = LrView.bind( "trainers" )
                       },
                       f:edit_field {
                          fill_horizontal = 1.0,
                          visible = LrView.bind("training_labels_visible"),
                          height_in_lines = 3,
                          value = LrView.bind( "training_labels" ),
                          placeholder_string = "training keywords",
                          auto_completion = true,
                          completion = LrView.bind( "trainer_existing_table" ),
                          enabled = true
                       },
                       f:scrolled_view {
                          margin = 2,
                          visible = LrView.bind("training_checkboxes_visible"),
                          horizontal_scroller = false,
                          height = 80,
                          training_label_rows
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:static_text {
                             title = "Exclude:"
                          },
                          f:edit_field {
                             fill_horizontal = 1.0,
                             placeholder_string = "keywords to exclude from train",
                             value = LrView.bind( "filter_training" )
                          }
                       },
                       f:row {
                          fill_horizontal = 1.0,
                          f:column {
                             place = "horizontal",
                             place_horizontal = 1.0,
                             f:push_button {
                                margin_right = 0,
                                title = "Train",
                                action = function()
                                   train()
                                end
                             }
                             
                          }
                       }
                    }
                 }
              }
           }
	    }

        LrTasks.startAsyncTask(function()
              utils.fetchKeywords(function(keywords)
                    props.keywords = keywords
              end)
              fetchTrees()
              fetchTrainers()
              LrDialogs.presentFloatingDialog(_PLUGIN, {
                 title = "CrossPrism Classifier",
                 contents = c,
                 blockTask = true,
                 saveFrame = true,
                 onShow = function()
                    log:trace( "in onShow" )
                 end,
                 windowWillClose = function()
                    prefs['filter_labels'] = props.filter_labels
                    prefs['parent_keyword_id'] = props.parent_keyword_id
                    prefs['filter_training'] = props.filter_training
                    prefs['send_hints'] = props.sendHints
                    prefs['highest_only'] = props.highest_only
                    prefs['use_keywords'] = props.useKeywords
                    prefs['use_title'] = props.useTitle
                    prefs['use_description'] = props.useDescription
                    prefs['use_exclude'] = props.useExclude
                    prefs['use_parent'] = props.useParent
                    prefs['singleclassify_treeid'] = props.treeid
                    prefs['singleclassify_subtreeid'] = props.subtreeid
                    prefs['scientific_name'] = props.scientific_name
                    log:trace( "window will close" )
                    floatingWillClose = true
                 end,
              })
        end)

        --neccessary or else some of the listeners get otherwise deallocated
        local lastTarget
        local catalog = LrApplication.activeCatalog()
        
        while not floatingWillClose do
           -- LrTasks.startAsyncTask(checkSelectedPhoto)
           local target = catalog:getTargetPhoto()
           if target ~= lastTarget then
              log:trace( "selection changed" )                                  
              lastTarget = target
              updateContents()              
           end
           updateBulkButton()
           LrTasks.sleep (0.5)
        end
	end) -- end main function

end


-- Now display the dialogs.
showCustomDialog()


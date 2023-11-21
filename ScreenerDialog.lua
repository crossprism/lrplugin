-- Screener Dialog for CrossPrism Lightroom Plugin
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

local utils = require 'utils.lua'
local mime = require 'mime.lua'

local log = LrLogger( 'ScreenerDialog' )
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

log:trace("loaded JSON")
local function showCustomDialog()
   local baseUrl = prefs.server_url
	LrFunctionContext.postAsyncTaskWithContext( "ScreenerDialog", function( context )
	    local f = LrView.osFactory()
        local trainers = {}

	    -- Create a bindable table.  Whenever a field in this table changes
	    -- then notifications will be sent.
	    local props = LrBinding.makePropertyTable( context )
        props.labels = ""
        props.filter_labels = "" --todo: save this into plugin config
        props.filter_training = ""
        props.image = nil
        props.existing = nil
        props.training_labels = nil
        props.photo_name = ""
        props.photo_width = 128
        props.photo_height = 128
        props.selection = ""
        props.results = ""
        props.screeners = {}
        props.screenerid = nil
        props.collection_option = "existing"
        props.collections = {}
        props.collection_existing = nil
        props.collection_new = ""
        props.synced_photos = {}
        props.cancel_visible = false
        props.send_enabled = true
        props.send_cancel = false
        props.keywords = {}

        local check_columns = 4
        local check_rows = 10
        local processSelected
        local processPhotos
        
        props = utils.initCheckboxLabels(props)
        
        props:addObserver('trainerid',function(propTable,key,value)
                             props = utils.trainerChange(trainers,value,props)
        end)
        
        local function sendImages()
           LrFunctionContext.postAsyncTaskWithContext("sendImages", function(context)
                 local catalog = LrApplication.activeCatalog()
                 local photos = catalog:getTargetPhotos()
                 log:tracef( "target Photos: %d", #photos )
                 local images = {}
                 local tasks = {}
                 local numRunning = 0
                 local countDown = #photos
                 local batchSize = 10
                 local counter = 0
                 
                 local checkBatch = function()
                    while numRunning > 0 and not props.send_cancel do
                       LrTasks.yield()
                       LrTasks.sleep(0.1)                  
                    end

                    if props.send_cancel then
                       return
                    end
                    if #images > batchSize then
                       local batchImages = images
                       images = {}
                       log:tracef("Batch size: %d",#batchImages)
                       --LrTasks.startAsyncTask(function()
                       utils.postScreenerSend(baseUrl,props.screenerid,batchImages)
                       --end)
                       countDown = countDown - batchSize
                    end
                    props.send_status_text = countDown .. " left"
                    LrTasks.yield()
                 end
                 
                 for i,photo in pairs(photos) do
                    log:tracef("num running: %d", numRunning)
                    local requestFunc = function(jpeg,reason)
                       local asyncFunc = function(context2)
                          context2:addCleanupHandler(function()
                                numRunning = numRunning - 1
                                tasks[i] = nil
                          end)

                          if reason ~= nil then
                             log:errorf("Reason: %s",reason)
                          end
                          -- log:tracef("Got image %d",i)
                          jsonMeta = utils.jsonPhotoMeta(photo)
                          local record = {
                             name = photo:getFormattedMetadata("fileName"),
                             image = jpeg,
                             id = photo:getRawMetadata("uuid"),
                             json = jsonMeta
                          }                          
                          images[#images+1] = record
                          -- log:tracef("Finishing image %d images: %d",i,#images)
                       end
                       LrFunctionContext.postAsyncTaskWithContext("sendImage2",asyncFunc)
                    end

                    if counter > batchSize then
                       checkBatch()
                       counter = 0
                    end
                    if props.send_cancel then
                       break
                    end
                    numRunning = numRunning + 1
                    local thumbSize = utils.maxDimUsingShortSide(photo,512)
                    tasks[i] = photo:requestJpegThumbnail(thumbSize,thumbSize,requestFunc)
                    counter = counter + 1
                 end
                 while numRunning > 0 do
                    LrTasks.yield()
                    LrTasks.sleep(0.1)                  
                 end
                 log:tracef("Done %s", #images)
                 if not props.send_cancel then
                    --LrTasks.startAsyncTask(function()
                          utils.postScreenerSend(baseUrl,props.screenerid,images)
                          --end)
                    props.send_status_text = #photos .. " sent"
                 else
                    props.send_status_text = "Cancelled"

                 end
                 props.send_enabled = true
                 props.cancel_visible = false
           end)
        end

        local function syncResults()
           LrTasks.startAsyncTask(function()
                 local ids = utils.screenerSync(baseUrl,props.screenerid)
                 local catalog = LrApplication.activeCatalog()
                 local photos = {}
                 if ids ~= nil then
                    for i,id in ipairs(ids) do
                       local photo = catalog:findPhotoByUuid(id)
                       if photo == nil then
                          photo = catalog:findPhotoByPath(id,false)
                       end
                       if photo ~= nil then
                          photos[#photos + 1] = photo
                       end
                    end
                    props.synced_photos = photos
                    processPhotos(photoRowCount,photos,nil,"sync")
                    props.results = #ids .. " results"
                 end
           end)
        end
        local function fetchScreeners()
           LrTasks.startAsyncTask(function()
                 trainersResult = utils.loadScreeners(baseUrl)
                 if trainersResult ~= nil then
                    trainers = trainersResult[1]
                    keyset = trainersResult[2]
                    if keyset ~= nil then
                       table.sort(keyset)
                       props.screeners = keyset
                       if props.screenerid == nil and #keyset > 0 then
                          props.screenerid = keyset[1]
                       end
                    end
                 end
           end)
        end        

        processSelected = function(photo)
           local existing = photo:getFormattedMetadata("keywordTags")
           log:tracef( "Existing keywords: %s",existing )
           props.existing = existing
           props.training_labels = existing
           --for name, photo in pairs(photos) do
           log:tracef( "photo name: %s", props.photo_name )
        end

        processPhotos = function(count,photos,selected,stem)
           local lastPhoto = nil
           for i=1,count do
              local photo = photos[i]
              if photo == nil then
                 props[stem..i] = lastPhoto
                 props[stem..i.."_background"] = LrColor(0.0,0.0,0.0)
                 props[stem..i.."_width"] = 0
                 props[stem..i.."_name"] = ""
                 props[stem..i.."_visible"] = false

              else
                 local name = photo:getFormattedMetadata("fileName")
                 props[stem..i.."_visible"] = true
                 props[stem..i.."_width"] = 128
                 if photo == selected then
                    name = name.."*"
                    processSelected(photo)
                    props[stem..i.."_background"] = LrColor(0.5,0.5,0.5) 
                    props[stem..i.."_framecolor"] = LrColor(0.5,0.5,0.5) 
                    selectedPhoto = photo
                 else
                    props[stem..i.."_background"] = LrColor(0.0,0.0,0.0)
                    props[stem..i.."_framecolor"] = LrColor(0.0,0.0,0.0)
                 end 

                 props[stem..i.."_name"] = name
                 props[stem..i] = photo
                 lastPhoto = photo
                 path = photo:getRawMetadata("path")
                 -- log:tracef("path: %s",path)
                 info = LrPhotoInfo.fileAttributes(path)
                 local scale = 1.0
                 if info.width > info.height then
                    scale = 128.0/info.width
                 else
                    scale = 128.0/info.height
                 end
                 props[stem..i.."_width"] = info.width * scale
                 props[stem..i.."_height"] = info.height * scale
              end
           end
        end
        local function checkSelectedPhoto()
           local catalog = LrApplication.activeCatalog()
           local selected = catalog:getTargetPhoto()
           if selectedPhoto ~= selected then
              log:trace( "selected changed" )
              processPhotos(photoRowCount,catalog:getTargetPhotos(), selected,"photo")
           end
        end
        local function updateContents(c)
           LrTasks.startAsyncTask(function()
                 local catalog = LrApplication.activeCatalog()
                 local photo = catalog:getTargetPhoto()
                 log:trace( "got target photo" )
                 local photos = catalog:getTargetPhotos()

                 local labels = {}
                 local lastLabel = ""

                 props.selection = #photos .. " selected"
                 processPhotos(photoRowCount,photos,photo,"photo")
                 --end
           end)
        end

        local function setSelection(view)
           log:tracef( "trying to set selection to index")
           local catalog = LrApplication.activeCatalog()
           local photos = catalog:getTargetPhotos()

           local newSelection = view.photo
           if newSelection ~= nil then
              catalog:setSelectedPhotos(newSelection,photos)
              -- processPhotos(photoRowCount,photos, newSelection)
           end
        end

        local function buildPhotoColumns(stem, count, mouseFunc)
           local photo_columns = {}
           for i=1,count do
              photo_columns[#photo_columns+1] = f:column {
                 spacing = 0,
                 f:catalog_photo {
                    photo = LrView.bind( stem..i ),
                    width = 128,
                    height = 128,
                    frame_width = 2,
                    frame_color = LrView.bind(stem..i.."_framecolor"),
                    visible = LrView.bind( stem..i.."_visible" ),
                    background_color = LrView.bind( stem..i.."_background" ),
                    mouse_down = mouseFunc
                 },
                 f:static_text {
                    title = LrView.bind( stem..i.."_name" )
                 }                  
              }
           end
           return photo_columns
        end

        local function doSave()
           local catalog = LrApplication.activeCatalog()
           local collection_name
           local collection
           local photos = props.synced_photos

           local function addPhotosToCollection(photos)
              catalog:withWriteAccessDo("Create Collection", function(context)
                                           collection:addPhotos(photos)
                                           catalog:setActiveSources({collection})
              end, { timeout = 5})
           end                    

           catalog:withWriteAccessDo("Create Collection", function(context)
                                        if props.collection_option == "existing" then
                                           collection = catalog:getCollectionByLocalIdentifier(props.collection_existing)
                                        else
                                           collection = catalog:createCollection(props.collection_new,nil,true)
                                        end
                                        log:tracef("Collection created: %s",collection)
                                        if collection ~= nil then
                                           LrTasks.startAsyncTask(function()
                                                 addPhotosToCollection(photos)
                                           end)
                                        end

           end, { timeout = 1})

        end
	    -- Create the contents for the dialog.
        local photo_columns = buildPhotoColumns("photo",photoRowCount,function(view) 
                    setSelection(view)
        end)
        
        local photos_row = f:scrolled_view {
           margin = 4,
           width = 550,
           height = 156,
           background_color = LrColor(0.0,0.0,0.0),
           horizontral_scroller = true,
           f:row(photo_columns)
        }

        local sync_columns = buildPhotoColumns("sync",photoRowCount)
        local sync_row = f:scrolled_view {
           margin = 4,
           width = 550,
           height = 156,
           background_color = LrColor(0.0,0.0,0.0),
           horizontral_scroller = true,
           f:row(sync_columns)
        }


	    local c = f:column {
           margin = 10,
           width = 512,
           height = 340,
           place = "vertical",
           -- Bind the table to the view.  This enables controls to be bound
		    -- to the named field of the 'props' table.
		    
           bind_to_object = props,
           f:row {
              fill_horizontal = 1.0,
              place_vertical = 0.0,
              f:static_text {
                 title = "Screener"
              },
              f:popup_menu {
                 value = LrView.bind( "screenerid" ),
                 items = LrView.bind( "screeners" )
              },
           },
           f:spacer {
              height = 12
           },
           f:group_box {                 
              title = "Transfer Photos to Screener",
              fill_horizontal = 1.0,
              f:row {
                 fill_horizontal = 1.0,
                 f:column {
                    fill_horizontal = 1.0,
                    photos_row,
                    f:static_text {
                       title = LrView.bind("selection")
                    },
                 },
                 f:column {
                    f:push_button {
                       title = "Cancel",
                       visible = LrView.bind("cancel_visible"),
                       action = function(button)
                          props.send_cancel = true
                       end
                    },                    

                    f:push_button {
                       title = "Send",
                       visible = LrView.bind("send_enabled"),
                       action = function()
                          props.cancel_visible = true
                          props.send_enabled = false
                          props.send_cancel = false
                          sendImages()
                       end
                    },
                    f:static_text {
                       title = LrView.bind("send_status_text"),
                       truncation = "middle",
                       width_in_chars = 20
                    },

                 }
              },
           },
           f:spacer {
              height = 12
           },
           f:group_box {
              title = "Screener Results",
              fill_horizontal = 1.0,
              f:row {
                 fill_horizontal = 1.0,
                 f:column {
                    sync_row,
                    f:static_text {
                       title = LrView.bind("results")
                    }
                 },
                 f:column {
                    f:push_button {
                       title = "Sync",
                       action = function()
                          syncResults()
                       end
                       
                    }
                 }
              },
              f:row {
                 fill_horizontal = 1.0,
                 place_horizontal = 1.0,
                 f:radio_button {
                    title = "Add to Collection:",
                    value = LrView.bind("collection_option"),
                    checked_value = "existing"
                 },
                 f:popup_menu {
                    value = LrView.bind("collection_existing"),
                    items = LrView.bind("collections"),
                 },
                 f:radio_button {
                    title = "New:",
                    value = LrView.bind("collection_option"),
                    checked_value = "new"
                 },
                 f:edit_field {
                    value = LrView.bind("collection_new")
                 },
                 f:push_button {
                    margin_right = 0,
                    title = "Save",
                    action = function()
                       LrFunctionContext.postAsyncTaskWithContext("processSave",
                                                                  doSave)
                    end
                 }
              },
              f:row {
                 fill_horizontal = 1.0,
                 f:edit_field {
                    width = 550,
                    height_in_lines = 2,
                    placeholder_string = "keywords",
                    value = LrView.bind( "labels" ),
                    auto_completion = true,
                    completion = LrView.bind( "keywords" )
                 },
                 f:push_button {
                    title = "Apply",
                    action = function()
                       for i,photo in pairs(props.synced_photos) do
                          utils.addKeywords(photo, props.labels)
                       end
                    end
                 }
              }
           },
        }

        LrTasks.startAsyncTask(function()
              log:trace( "in async" )
              utils.fetchKeywords(function(keywords)
                    props.keywords = keywords
              end)
              fetchScreeners()
              utils.fetchCollections(function(collections,sets)
                    props.collections = utils.prepCollections(collections)
              end)
              LrDialogs.presentFloatingDialog(_PLUGIN, {
                 title = "CrossPrism Screener",
                 contents = c,
                 blockTask = true,
                 onShow = function()
                    log:trace( "in onShow" )
                    updateContents(c)
                 end,
                 selectionChangeObserver = function()
                    log:trace( "in selection changed" )
                    updateContents(c)
                 end,
                 windowWillClose = function()
                    log:trace( "window will close" )
                    floatingWillClose = true
                 end,
              })

        end)

        while not floatingWillClose do
           -- LrTasks.startAsyncTask(checkSelectedPhoto)
           LrTasks.sleep (1.0)
        end
	end) -- end main function

end

-- Now display the dialogs.
showCustomDialog()


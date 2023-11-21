-- Trainer Dialog for CrossPrism Lightroom Plugin
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

local log = LrLogger( 'TrainerDialog' )
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
	LrFunctionContext.postAsyncTaskWithContext( "TrainerDialog", function( context )
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
        props.trainers = {}
        props.trainerid = nil
        props.trainer_existing_labels = nil
        props.trainer_existing_table = {}
        props.training_checkboxes_visible = false
        props.training_labels_visible = true

        local check_columns = 4
        local check_rows = 10
        local processSelected

        props = utils.initCheckboxLabels(props)
        
        props:addObserver('trainerid',function(propTable,key,value)
                             props = utils.trainerChange(trainers,value,props)
        end)

        local function fetchTrainers()
           LrTasks.startAsyncTask(function()
                 trainersResult = utils.loadTrainers(baseUrl,true)
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
                 local catalog = LrApplication.activeCatalog()
                 local labels = props.training_labels
                 local multilabels = utils.getCheckmarkLabels(props)
                 
                 labels = utils.mergeCSV(labels,multilabels)
                 
                 local photos = catalog:getTargetPhotos()
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


        processSelected = function(photo)
           local existing = photo:getFormattedMetadata("keywordTags")
           log:tracef( "Existing keywords: %s",existing )
           props.existing = existing
           props.training_labels = existing
           --for name, photo in pairs(photos) do
           log:tracef( "photo name: %s", props.photo_name )
        end

        local function processPhotos(count,photos,selected)
           local lastPhoto = nil
           for i=1,count do
              local photo = photos[i]
              if photo == nil then
                 props["photo"..i] = lastPhoto
                 props["photo"..i.."_background"] = LrColor(0.0,0.0,0.0)
                 props["photo"..i.."_width"] = 0
                 props["photo"..i.."_name"] = ""
                 props["photo"..i.."_visible"] = false

              else
                 local name = photo:getFormattedMetadata("fileName")
                 props["photo"..i.."_visible"] = true
                 props["photo"..i.."_width"] = 128
                 if photo == selected then
                    name = name.."*"
                    processSelected(photo)
                    props["photo"..i.."_background"] = LrColor(0.5,0.5,0.5) 
                    props["photo"..i.."_framecolor"] = LrColor(0.5,0.5,0.5) 
                    selectedPhoto = photo
                 else
                    props["photo"..i.."_background"] = LrColor(0.0,0.0,0.0)
                    props["photo"..i.."_framecolor"] = LrColor(0.0,0.0,0.0)
                 end 

                 props["photo"..i.."_name"] = name
                 props["photo"..i] = photo
                 lastPhoto = photo
                 path = photo:getRawMetadata("path")
                 log:tracef("path: %s",path)
                 info = LrPhotoInfo.fileAttributes(path)
                 local scale = 1.0
                 if info.width > info.height then
                    scale = 128.0/info.width
                 else
                    scale = 128.0/info.height
                 end
                 props["photo"..i.."_width"] = info.width * scale
                 props["photo"..i.."_height"] = info.height * scale
              end
           end
        end
        local function checkSelectedPhoto()
           local catalog = LrApplication.activeCatalog()
           local selected = catalog:getTargetPhoto()
           if selectedPhoto ~= selected then
              log:trace( "selected changed" )
              processPhotos(photoRowCount,catalog:getTargetPhotos(), selected)
           end
        end
        local function updateContents(c)
           LrTasks.startAsyncTask(function()
                 props.labels = "...."
                 props.labels_enabled = false
                 local catalog = LrApplication.activeCatalog()
                 local photo = catalog:getTargetPhoto()
                 log:trace( "got target photo" )
                 local photos = catalog:getTargetPhotos()

                 local labels = {}
                 local lastLabel = ""

                 props.selection = #photos .. " selected"
                 processPhotos(photoRowCount,photos,photo)
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
	    -- Create the contents for the dialog.
        local photo_columns = {}

        for i=1,photoRowCount do
           photo_columns[#photo_columns+1] = f:column {
              f:catalog_photo {
                 photo = LrView.bind( "photo"..i ),
                 width = 128,
                 height = 128,
                 frame_width = 2,
                 frame_color = LrView.bind("photo"..i.."_framecolor"),
                 visible = LrView.bind( "photo"..i.."_visible" ),
                 background_color = LrView.bind( "photo"..i.."_background" ),
                 mouse_down = function(view) 
                    setSelection(view)
                 end
              },
              f:static_text {
                 title = LrView.bind( "photo"..i.."_name" )
              }                  
           }
        end
        photo_columns.spacing = 0
        local photos_row = f:scrolled_view {
           margin = 4,
           width = 500,
           height = 156,
           background_color = LrColor(0.0,0.0,0.0),
           horizontral_scroller = true,
           f:row(photo_columns)
        }

        local training_label_rows = f:column( utils.initCheckboxRows(props) )


	    local c = f:column {
           margin = 10,
           width = 512,
           height = 340,
           place = "vertical",
           -- Bind the table to the view.  This enables controls to be bound
		    -- to the named field of the 'props' table.
		    
           bind_to_object = props,
           photos_row,
           f:row {
              f:static_text {
                 title = LrView.bind("selection")
              },
           },
           f:row {
              fill_horizontal = 1.0,
              place_vertical = 0.0,
              f:static_text {
                 title = "Trainer"
              },
              f:popup_menu {
                 value = LrView.bind( "trainerid" ),
                 items = LrView.bind( "trainers" )
              },
           },
           f:column {
              fill_horizontal = 1.0,              
              f:edit_field {
                 fill_horizontal = 1.0,
                 height_in_lines = 3,
                 visible = LrView.bind("training_labels_visible"),
                 value = LrView.bind( "training_labels" ),
                 placeholder_string = "training keywords",
                 auto_completion = true,
                 completion = LrView.bind( "trainer_existing_table" ),
                 enabled = true
              },              
              f:scrolled_view {
                 width = 500,
                 visible = LrView.bind("training_checkboxes_visible"),
                 horizontal_scroller = false,
                 height = 80,
                 training_label_rows
              },
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 fill_horizonal = 1.0,
                 place_horizontal = 1.0,
                 f:push_button {
                    margin_right = 0,
                    title = "Train",
                    action = function()
                       train()
                    end
                 }
              }
           },
        }

        LrTasks.startAsyncTask(function()
              log:trace( "in async" )
              fetchTrainers()
              LrDialogs.presentFloatingDialog(_PLUGIN, {
                 title = "CrossPrism Trainer",
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


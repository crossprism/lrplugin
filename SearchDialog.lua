-- Search Dialog for CrossPrism Lightroom Plugin
--

-- Access the Lightroom SDK namespaces.
local LrDate = import 'LrDate'
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
local LrErrors = import 'LrErrors'

local prefs = import 'LrPrefs'.prefsForPlugin()

local utils = require 'utils.lua'
local mime = require 'mime.lua'
local base64 = require 'base64.lua'

local log = LrLogger( 'SearchDialog' )
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
local use_cache = prefs.use_cache

local function isBlack(color)
   return color:red() == 0 and color:blue() == 0 and color:green() == 0
end

local function dumpFeatures(features)
   log:tracef("features: {%s}",utils.tableToString(features))
end

local function requestPhotoFeatures(jpeg,photo,callback)
   local baseUrl = prefs.server_url
   local headers = {
      { field = 'Content-Type', value = "image/jpeg" }
   }
   local result,hdrs = LrHttp.post( baseUrl.."/extract", jpeg, headers)
   if result ~= nil then
      --log:tracef("good result: %s",result)
      local lua_value = JSON:decode(result)
      local features = lua_value["features"]
      local extractor = lua_value["extractor"]
      --log:tracef("features: %s",features)
      local featuresExtractor = { extractor = extractor }
      callback(photo,features,featuresExtractor)
      return features
   end
   log:error("Network request failed to get features")
   return nil
end

local function writeFeatures(photo,features,extractor)
   if use_cache then
      local catalog = LrApplication.activeCatalog()
      local timestamp = LrDate.currentTime()
      catalog:withPrivateWriteAccessDo(function()            
            photo:setPropertyForPlugin(_PLUGIN, 'features',features)
            photo:setPropertyForPlugin(_PLUGIN,'features_extractor',extractor)
            photo:setPropertyForPlugin(_PLUGIN,'features_date',timestamp)
      end, {timeout = 1})
   end
end

local function writeValues(photo,values)
   local catalog = LrApplication.activeCatalog()
   local existing = photo:getPropertyForPlugin(_PLUGIN,'extended_attributes')
   local timestamp = LrDate.currentTime()
   if existing == nil then
      existing = {}
   end
   for key,val in pairs(values) do
      existing[key] = val
   end
   log:tracef("Writing values: %s",utils.tableToString(existing))
   catalog:withPrivateWriteAccessDo(function()            
         photo:setPropertyForPlugin(_PLUGIN,'extended_attributes',existing)
         photo:setPropertyForPlugin(_PLUGIN,'extended_date',timestamp)
   end, {timeout = 1})
end


local function findCentroid(features)
   local totals = {}
   --log:tracef("centroid feature count: %d",#features)
   for i,record in ipairs(features) do
      if i == 1 then
         totals = record['features']
      else
         for i,v in ipairs(record['features']) do
            totals[i] = totals[i] + v
         end
      end
   end
   --log:tracef("centroid totals: %s",utils.tableToString(totals))
   local centroid = {}
   for i,val in ipairs(totals) do
      centroid[i] = val / #features
   end
   return centroid
end

local function computeCartesianDistance(a,b)
   local total = 0
   for i,v in ipairs(a) do
      total = total + math.pow(v-b[i],2)
   end
   local dist = math.sqrt(total)
   --log:tracef("a size: %d, b size: %d, distance: %f",#a,#b,dist)
   return dist
end

local function computeLength(a)
   local total = 0
   for i,v in ipairs(a) do
      total = total + math.pow(v,2)
   end
   return math.sqrt(total)
end

local function computeCosDistance(a,b)
   local total = 0
   for i,v in ipairs(a) do
      total = total + v * b[i]
   end
   local dist = 1 + total / (computeLength(a) * computeLength(b))
   return dist
end


local function leastDistancePhotos(similar,dissimilar,features,factor, isAbsolute)
   if #similar > 0 then
      log:tracef("reference feature: %s",utils.tableToString(similar[1]['features']))
   end
   local centroid = findCentroid(similar)
   local centroid2 = findCentroid(dissimilar)
   local distances = {}

   log:tracef("centroid feature: %s",utils.tableToString(centroid))
   local totaldist = 0
   local totalsqr = 0
   local origfactor = factor
   if #centroid > 0 and #centroid2 == 0 then
      factor = factor + 50
   end
   if #centroid2 > 0 and #centroid == 0 then
         factor = factor - 50
   end
   
   log:tracef("factor: %f",factor)
   
   for i,record in ipairs(features) do
      local distance = 0
      if #centroid > 0 then
         distance = computeCartesianDistance(centroid,record['features'])
      end
      if #centroid2 > 0 then
         distance = distance - computeCartesianDistance(centroid2,record['features'])
      end
      
      totaldist = totaldist + distance
      totalsqr = totalsqr + math.pow(distance,2)
      distances[i] = {distance = distance,
                      photo = record['photo']}
   end

   if isAbsolute then
      distthreshold = factor
   else
      --local mean = totaldist / #features
      local mean = 0
      local variance = (totalsqr - 2 * totaldist * mean + mean * mean * #features) / (#features - 1)
      local stddev = math.sqrt(variance)
      log:tracef("mean: %f, var: %f, stddev: %f",mean,variance, stddev)
      --distthreshold = mean - stddev * factor
      distthreshold = stddev * 1/math.exp(factor)
   end
   for i,dist in ipairs(distances) do
      log:tracef("distance: %f",dist['distance'])
   end

   table.sort(distances, function(a,b)
                 return a['distance'] < b['distance']
   end)

   final = {}
   for i,dist in ipairs(distances) do
      if dist['distance'] <= distthreshold then
         final[#final + 1] = dist['photo']
      else
         break
      end
   end
   return final
end


local function showCustomDialog()
   local baseUrl = prefs.server_url
	LrFunctionContext.postAsyncTaskWithContext( "SearchDialog", function( context )
	    local f = LrView.osFactory()
        local trainers = {}

	    -- Create a bindable table.  Whenever a field in this table changes
	    -- then notifications will be sent.
	    local props = LrBinding.makePropertyTable( context )
        props.labels = ""
        props.all_or_collection = "all"
        props.search_collection = nil
        props.collection_values = {}
        props.search_set = ""
        props.set_values = {}
        
        props.search_keywords = ""
        props.search_keywords_tree = ""
        props.search_keywords_subtree = ""
        props.search_similar_images = {}
        props.search_dissimilar_images = {}
        props.trees = {}
        props.treeid = nil
        props.keywords_checkbox = false
        
        props.text_checkbox = false
        props.search_text = ""

        props.saliency_checkbox = false
        
        props.similar_checkbox = false
        props.dissimilar_checkbox = false
        props.similar_photo = nil
        props.dissimilar_photo = nil
        props.similar_total = ""
        props.dissimilar_total = ""

        
        props.nima_checkbox = false
        props.nima_min = nil
        props.nima_max = nil
        
        props.people_checkbox = false
        props.people_min = nil
        
        props.huemean_checkbox = false
        props.huemean_min = nil
        props.huemean_max = nil

        props.huemean_min_color = nil
        props.huemean_max_color = nil
        props.huemean_min_color_x_visible = false
        props.huemean_max_color_x_visible = false
        
        props.brightness_checkbox = false
        props.brightness_min = nil
        props.brightness_max = nil

        props.brightness_min_color = nil
        props.brightness_max_color = nil
        props.brightness_min_color_x_visible = false
        props.brightness_max_color_x_visible = false

        props.aspect_checkbox = false
        props.aspect_min = nil
        props.aspect_max = nil

        props.similar_distribution = true
        props.similar_factor = 20.0
        props.force_load_checkbox = false

        props.faces_checkbox = false
        props.faces_min = nil
        
        props.huestd_checkbox = false
        props.huestd_min = nil
        props.huestd_max = nil
        
        props.saturation_checkbox = false
        props.saturation_min = nil
        props.saturation_max = nil
        props.saturation_min_color = nil
        props.saturation_max_color = nil
        props.saturation_min_color_x_visible = false
        props.saturation_max_color_x_visible = false

        
        props.nsfw_checkbox = false
        props.nsfw = false

        props.output_collection = prefs.search_output_collection
        props.collection_append = prefs.search_collection_append
        props.search_enabled = true
        props.cancel_visible = false
        props.cancel = false

        if props.output_collection == nil or props.output_collection == "" then
           props.output_collection = "CrossPrism"
        end

        if props.collection_append == nil then
           props.collection_append = false
        end
        
        props:addObserver('treeid',function(propTable,key,value)
                             log:trace("in treeid observer")
                             props.subtrees = utils.prepSubtrees(loadedTrees[value])
                             props.subtreeid = '-'
                             LrTasks.startAsyncTask(function()
                                   local catalog = LrApplication.activeCatalog()
                                   local photo = catalog:getTargetPhoto()
                                   log:trace("in treeid observer3")                             
                             end)
        end)

        props:addObserver('subtreeid',function(propTable,key,value)
                             log:trace("in subtreeid observer")
                             LrTasks.startAsyncTask(function()
                                   local catalog = LrApplication.activeCatalog()
                                   local photo = catalog:getTargetPhoto()
                                   log:trace("in subtreeid observer3")                             
                             end)
        end)
        props:addObserver('search_collection',function(propTable,key,value)
                             if props.search_collection ~= nil then
                                props.all_or_collection = 'collection'
                             end
        end)
        props:addObserver('search_set',function(propTable,key,value)
                             if props.search_set ~= nil then
                                props.all_or_collection = 'set'
                             end
        end)

        local function handleColorWell(color,colorChannel,key)
           if color == nil or isBlack(color) then
              props[key] = nil
           else
              local h,s,v = utils.RGBToHSV(color:red(),color:green(),color:blue())
              local t = {h=h, s=s, v=v}
              props[key] = t[colorChannel]
              props[key..'_color_x_visible'] = true
           end           
        end
        props:addObserver('huemean_min_color',function(propTable,key,value)
                             handleColorWell(value,'h','huemean_min')
        end)
        props:addObserver('huemean_max_color',function(propTable,key,value)
                             handleColorWell(value,'h','huemean_max')
        end)
        props:addObserver('saturation_min_color',function(propTable,key,value)
                             handleColorWell(value,'s','saturation_min')
        end)
        props:addObserver('saturation_max_color',function(propTable,key,value)
                             handleColorWell(value,'s','saturation_max')
        end)
        props:addObserver('brightness_min_color',function(propTable,key,value)
                             handleColorWell(value,'v','brightness_min')
        end)
        props:addObserver('brightness_max_color',function(propTable,key,value)
                             handleColorWell(value,'v','brightness_max')
        end)


        local function tic(delay)
           if delay == nil then
              delay = 0
           end
           local now = os.time()
           local ellapsed = 0
           while (ellapsed <= delay) do
              if props.cancel then
                 props.status_text = "Cancelling..."
                 LrErrors.throwCanceled()
              end
              LrTasks.yield()
              if delay > 0 then
                 log:trace("delaying...")
                 LrTasks.sleep(0.1)
                 ellapsed = ellapsed + os.time() - now
              else
                 ellapsed = 1
              end

           end
        end

        local function displayResultsInCollection(result,collection_name)
           local catalog = LrApplication.activeCatalog()
           local collection

           local function addPhotosToCollection(photos)
              catalog:withWriteAccessDo("Create Collection", function(context)
                                           collection:addPhotos(photos)
                                           catalog:setActiveSources({collection})
              end, { timeout = 5})
           end
           catalog:withWriteAccessDo("Create Collection", function(context)
                                        collection = catalog:createCollection(collection_name,nil,true)
                                        if not props.collection_append then
                                           collection:removeAllPhotos()
                                        end     
                                        LrTasks.startAsyncTask(function()
                                              addPhotosToCollection(result)
                                        end)

           end, { timeout = 1})
        end
        
        local function fetchTrees()
           LrTasks.startAsyncTask(function()
                 treeResults = utils.loadTrees(baseUrl)
                 if treeResults ~= nil then
                    loadedTrees = treeResults[1]
                    props.trees = utils.prepTrees(treeResults[2])
                    if props.treeid == nil then
                       props.treeid = "default"
                    end
                 end
           end)
        end

        local function getPhotoFeatures(photos,update_callback)
           local featuresTable = {}
           local numRunning = 0
           local maxParallel = 8
           local tasks = {}
           for i,photo in ipairs(photos) do
              update_callback(i,#photos)
              features = photo:getPropertyForPlugin(_PLUGIN,'features')
              extractor = photo:getPropertyForPlugin(_PLUGIN,'features_extractor')

              local thumbCallback = function(jpeg,reason)
                 log:tracef( "got jpeg for index %d",i )
                 local asyncFunc = function(context)
                    context:addCleanupHandler(function()
                          numRunning = numRunning - 1
                          tasks[i] = nil
                    end)
                    context:addFailureHandler(function(status,msg)
                          log:errorf("Failed during http post: %s",msg)
                    end)

                    requestPhotoFeatures(jpeg,photo,
                                         function(photo, features, extractor)
                                            if features ~= nil then
                                               log:trace( "successfully received features" )
                                               writeFeatures(photo,features,extractor)
                                               log:tracef("Got features: %d",#features)
                                               featuresTable[#featuresTable + 1] = { photo = photo,
                                                                                     features = features,
                                                                                     extractor = extractor }
                                            else
                                               log:trace("Failed to get features")
                                            end
                                            
                    end)
                 end
                 
                 LrFunctionContext.postAsyncTaskWithContext("getPhotoFeatures",asyncFunc)
              end
              if features == nil then
                 numRunning = numRunning + 1
                 log:tracef("Getting thumbnail...index %d",i)
                 local thumbSize = utils.maxDimUsingShortSide(photo,512)
                 tasks[i] = photo:requestJpegThumbnail(thumbSize,thumbSize,thumbCallback)
              else
                 featuresTable[#featuresTable + 1] = { photo = photo,
                                                       features = features,
                                                       extractor = extractor }
              end
              while (numRunning > maxParallel) do
                 tic(0.5)
                 --log:tracef("tasks: %s",utils.tableToString(tasks))
              end
           end

           while (numRunning > 0) do
              tic(0.5)
           end
           return featuresTable
        end

        local function buildOptions(cached)
           local options = {}
           if cached == nil then
              cached = {}
           end
           
           if props.keywords_checkbox then
              options[#options + 1] = "classify"
           end
           if props.saliency_checkbox then
              options[#options + 1] = "saliency"
           end
           if props.nima_checkbox and cached['nimaScore'] == nil then
              options[#options + 1] = "nima"
           end
           if props.people_checkbox and cached['people'] == nil then
              options[#options + 1] = "people"
           end

           if props.faces_checkbox and cached['faces'] == nil then
              options[#options + 1] = "faces"
           end

           if props.text_checkbox and cached['recognized_text'] == nil then
              options[#options + 1] = "text"
           end
           if (props.huemean_checkbox or props.huestd_checkbox or props.brightness_checkbox or props.saturation_checkbox or props.aspect_checkbox) and cached['aspect_ratio'] == nil then
              options[#options + 1] = "analysis"
           end

           if props.nsfw_checkbox and cached['nsfw'] == nil then
              options[#options + 1] = "nsfw"
           end

           -- if no classifier options are invoked, don't return any options
           if #options == 0 then
              return nil
           end
           
           return utils.tableToString(options)
        end

        local function filterKeywords(labels)
           local retPhotos = {}
           keywords = utils.csvToTableKeys(props.search_keywords)
           for j,label in ipairs(labels) do
              label = string.lower(label)
              --if keywords[label] ~= nil then
              --return true
              --end
              for keyword,b in pairs(keywords) do
                 if string.find(label,keyword) ~= nil then
                    return true
                 end
              end
           end
           return false
        end

        local function filterText(values,key,search)
           local textTable = values[key]
           for i,val in ipairs(textTable) do
              if string.find(string.lower(val),search) ~= nil then
                 return true
              end
           end
           return false
        end
        
        local function filterValues(values,key,min,max)
           local value = values[key]
           local retVal = true

           if value ~= nil then
              min = tonumber(min)
              if min ~= nil then
                 retVal = retVal and value >= min
              end
              if max ~= nil then
                 max = tonumber(max)
                 retVal = retVal and value < max
              end
           else
              log:errorf("Missing %s from values",key)
           end
           return retVal
        end
        
        local function filterPhoto(photo,classifyResults)
           local values = classifyResults['values']
           local labels = classifyResults['labels']
           local retVal = true
           if props.keywords_checkbox then
                 retVal = retVal and filterKeywords(labels)
           end
           local ranged = { nima = 'nimaScore',
                            aspect = 'aspect_ratio',
                            huemean = 'hue',
                            huestd = 'hue_deviation',
                            brightness = 'brightness',
                            saturation = 'saturation'
           }
           for key,val in pairs(ranged) do
              if props[key ..'_checkbox'] then
                 retVal = retVal and filterValues(values,val,props[key ..'_min'],
                                                  props[key ..'_max'])
              end
           end

           if props.text_checkbox then
              retVal = retVal and filterText(values,"recognized_text",props.search_text)
           end

           if props.nsfw_checkbox then
              retVal = retVal and (props.nsfw == (values['nsfw'] > 0.5))
           end
           return retVal
        end
        local function classify(photos,stepCallback,targetCollection,updateCollection)
           local retPhotos = {}
           local total = #photos
           local options = buildOptions()
           local maxParallel = 8
           local numRunning = 0
           local tasks = {}
           
           if options == nil then
              return photos
           end

           local catalog = LrApplication.activeCatalog()

           if updateCollection then 
              catalog:withWriteAccessDo("Create Collection", function(context)
                                           local collection = catalog:createCollection(targetCollection,nil,true)
                                           if not props.collection_append then
                                              collection:removeAllPhotos()
                                           end
              end)
           end
           
           for i,photo in ipairs(photos) do
              local features = nil
              local extractor = nil
              local postSucceeded = false
              local currentTask = nil
              local photoOptions
              stepCallback(i,total)
              --log:tracef("running: %d",numRunning)
              while ( numRunning >= maxParallel ) do
                 log:tracef("waiting for requests to finish...%d",numRunning)
                 tic(1)
              end
              local function addPhoto(photo)
                 retPhotos[#retPhotos + 1] = photo
                 if updateCollection then 
                    catalog:withWriteAccessDo("Create Collection", function(context)
                                                 local collection = catalog:createCollection(targetCollection,nil,true)
                                                 collection:addPhotos({photo})
                    end, {timeout = 1})
                 end
              end
              
              local function requestHandler(jpeg,reason)
                 log:tracef( "got jpeg for classify %d num running: %d",string.len(jpeg), numRunning )
                 local function httpHandle(context)
                    context:addCleanupHandler(function()
                          numRunning = numRunning - 1
                          tasks[i] = nil
                          --log:tracef("In cleanup %d",numRunning)
                    end)
                    context:addFailureHandler(function(status,msg)
                          log:errorf("Failed during http post: %s",msg)
                    end)

                    log:tracef("posting request...%d",i)
                                     
                    local headers = {
                       { field = 'Content-Type', value = "application/json" }         
                    }
                    if props.treeid ~= nil and props.treeid ~= "" then
                       local treepath = props.treeid
                       if props.subtreeid ~= '-' then
                          treepath = treepath.."/"..props.subtreeid
                       end
                       headers[#headers+1] = { field = 'X-Classifier-Tree', value = treepath }
                    end

                    if features == nil then
                       photoOptions = photoOptions .. ",return_feature"
                    end

                    headers[#headers+1] = { field = 'X-Classifier-Options', value = photoOptions }
                    --log:trace("encoding image...")

                    local imageBase64 = base64.enc(jpeg)
                    local requestTable = { image = imageBase64 }
                    if features ~= nil and extractor ~= nil then
                       requestTable['features'] = features              
                       requestTable['extractor'] = extractor['extractor']
                    end
                    
                    local json = JSON:encode(requestTable)
                    --if prefs.send_hints then
                    --headers[#headers+1] = { field = 'X-Classifier-Labels', value = props.existing }
                    --end

                    local result, hdrs = LrHttp.post( baseUrl.."/classify", json, headers )
                    log:tracef( "response: [%s]", result )
                    if result ~= nil then
                       local lua_value = JSON:decode(result)
                       lastLabel = lua_value['labels']
                       features = lua_value['returnFeatures']
                       if features ~= nil then
                          extractor = { extractor = features['extractor'] }
                          features = features['features']
                          
                          if features ~= nil then
                             writeFeatures(photo,features,extractor)
                          end
                       end
                       if lua_value['values'] ~= nil then
                          writeValues(photo,lua_value['values'])
                       end
                       if filterPhoto(photo,lua_value) then
                          addPhoto(photo)
                       end
                    else
                       log:error("Error during classify")
                    end
                 end
                 LrFunctionContext.postAsyncTaskWithContext("post",httpHandle)
              end
              
              -- Doing getPropertyForPlug in the thumbnail callback fails for some
              -- reason when the thumbnail is newly generated.
              features = photo:getPropertyForPlugin(_PLUGIN,'features',nil,true)
              if features ~= nil then
                 extractor = photo:getPropertyForPlugin(_PLUGIN,'features_extractor')
              end
              local values = photo:getPropertyForPlugin(_PLUGIN,'extended_attributes')
              if values ~= nil then
                 log:tracef("existing values: %s",utils.tableToString(values))
              end
              photoOptions = buildOptions(values)
              if photoOptions ~= nil then
                 log:tracef("Fetching thumbnail for %d",i)              
                 local thumbSize = utils.maxDimUsingShortSide(photo,512)
                 if props.saliency_checkbox then
                    thumbSize = 2048
                 end
                 tasks[i] = photo:requestJpegThumbnail(thumbSize,thumbSize,requestHandler)
                 if tasks[i] ~= nil then
                    numRunning = numRunning + 1
                 end
                    
              else
                 if filterPhoto(photo,{labels = {}, values = values}) then
                    addPhoto(photo)
                 end
              end
           end
           
           while (numRunning > 0) do
              log:tracef("finalizing...waiting for requests to finish...%d",numRunning)
              log:tracef("tasks: %s",utils:tableToString(tasks))
              tic(0.5)
           end
           return retPhotos
        end

        local function setSelection(view)
           local catalog = LrApplication.activeCatalog()
           local photos = catalog:getTargetPhotos()
        end
                
        local function fetch_callback(step,total)
           props.status_text = string.format("Fetching %d out of %d",step,total)
           tic()
        end

        local function process_callback(step,total)
           props.status_text = string.format("Processing %d out of %d",step,total)
           tic()
        end

        local function getCollectionSetPhotos(collection_set)
           local retVal = {}
           for i,childSet in ipairs(collection_set:getChildCollectionSets()) do
              local childResults = getCollectionSetPhotos(childSet)
              retVal = utils.appendTable(retVal,childResults)
           end
           log:tracef("Found %d in collection sets",#retVal)
           for i,collection in ipairs(collection_set:getChildCollections()) do
              local colPhotos = collection:getPhotos()
              retVal = utils.appendTable(retVal,colPhotos)
           end
           log:tracef("Found %d after collection",#retVal)
           return retVal
        end
        
        local function doSearch(context)
           context:addCleanupHandler(function()
                 props.search_enabled = true
                 props.cancel_visible = false
                 props.status_text = ""
           end)

           context:addFailureHandler(function(status,msg)
                 log:error(msg)
           end)

           local targetCollection = props.output_collection
           local catalog = LrApplication.activeCatalog()
           local photos = {}
           local force = props.force_load_checkbox
           if props.all_or_collection == "collection" then

              log:tracef("search collections: %s", props.search_collection)
              local collection = catalog:getCollectionByLocalIdentifier(props.search_collection)
              photos = collection:getPhotos()
           elseif props.all_or_collection == "set" then
              log:tracef("search set: %s", props.search_set)
              local collection = props.search_set
              photos = getCollectionSetPhotos(collection)

           elseif props.all_or_collection == "selected" then
              photos = catalog:getTargetPhotos()
           else
              photos = catalog:getAllPhotos()
           end

           if force then
              utils.clearCache(photos)
              if props.similar_checkbox then
                 utils.clearCache(props.search_similar_images)
              end
              if props.dissimilar_checkbox then
                 utils.clearCache(props.search_dissimilar_images)
              end
           end
           -- do not update the collection if it must re-update the
           -- set due to distance checking
           local updateCollection = not ( props.similar_checkbox or props.dissimilar_checkbox )
           
           photos = classify(photos,process_callback,targetCollection,updateCollection)

           if props.similar_checkbox or props.dissimilar_checkbox then
              local features = getPhotoFeatures(photos,fetch_callback)
              local similar = {}
              if props.similar_checkbox then
                 similar = getPhotoFeatures(props.search_similar_images,fetch_callback)
              end
              
              local dissimilar = {}
              if props.dissimilar_checkbox then
                 dissimilar = getPhotoFeatures(props.search_dissimilar_images,fetch_callback)
              end
              photos = leastDistancePhotos(similar,dissimilar,features,-props.similar_factor,true)
           end

           -- collections won't have duplicates. In append situations without
           -- similarity checking, it will
           -- be re-adding photos, but that's ok.
           displayResultsInCollection(photos,targetCollection)
        end
        
	    local c = f:row {
           margin = 10,
           width = 640,
           height = 300,
           place = "vertical",
           bind_to_object = props,
           -- Bind the table to the view.  This enables controls to be bound
		    -- to the named field of the 'props' table.
           f:row {
              fill_horizontal = 1.0,
              f:static_text {
                 title = "Search: "
              },
              f:radio_button {
                 title = "All",
                 value = LrView.bind( "all_or_collection"),
                 checked_value = "all"
                 
              },
              f:radio_button {
                 title = "Selected:",
                 value = LrView.bind( "all_or_collection"),
                 checked_value = "selected"
                 
              },
              f:radio_button {
                 title = "Collection:",
                 value = LrView.bind( "all_or_collection"),
                 checked_value = "collection"
              },
              f:popup_menu {
                 value = LrView.bind("search_collection"),
                 items = LrView.bind("collection_values")
              },
              f:radio_button {
                 title = "Set:",
                 value = LrView.bind( "all_or_collection"),
                 checked_value = "set"
              },
              f:popup_menu {
                 value = LrView.bind("search_set"),
                 items = LrView.bind("set_values")
              },
              f:push_button {
                 title = "Update",
                 action = function(button)
                    utils.fetchCollections(function(collections,sets)
                          props.collection_values = utils.prepCollections(collections)
                          props.set_values = utils.prepCollectionSets(sets)
                    end)
                 end
              }
           },
           f:row {
              f:checkbox {
                 value = LrView.bind("keywords_checkbox"),
                 checked_value = true,
                 unchecked_value = false,
                 title = "Predicted keywords contains: ",
                 fill_horizontal = 1.0,
              },
              f:edit_field {
                 value = LrView.bind("search_keywords"),
                 placeholder_string = "Comma separated values",
                 width_in_chars = 36
              },
              f:column {
                 fill_horizontal = 1.0
              }
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 fill_horizontal = 1.0,
              },
              f:static_text {
                 title = "Domain:  "
              },
              f:popup_menu {
                 value = LrView.bind("treeid"),
                 items = LrView.bind("trees"),
              },
              f:popup_menu {
                 value = LrView.bind("subtreeid"),
                 items = LrView.bind("subtrees"),
              },
              f:push_button {
                 title = "Reload",
                 action = function()
                    fetchTrees()
                 end
              },
              f:checkbox {
                 title = "Focus Crop",
                 value = LrView.bind("saliency_checkbox")
              }
           },
           f:row {
              f:checkbox {
                 value = LrView.bind("text_checkbox"),
                 checked_value = true,
                 unchecked_value = false,
                 title = "Recognized text contains: ",
                 placeholder_string = "Comma separated values",
                 fill_horizontal = 1.0,
              },
              f:edit_field {
                 value = LrView.bind("search_text"),
                 width_in_chars = 36
              },
              f:column {
                 fill_horizontal = 1.0
              }
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 f:checkbox {
                    value = LrView.bind("similar_checkbox"),
                    title = "Similar to images",
                 },
                 f:column {
                    f:row {
                       f:spacer {
                          width = 16
                       },
                       f:column {
                          f:catalog_photo {
                             photo = LrView.bind("similar_photo"),
                             margin = 64,
                             width = 64,
                             height = 64,
                             visible = true
                          },
                          f:static_text {
                             title = LrView.bind("similar_total")
                          }
                       }
                    },
                    f:row {
                       f:push_button {
                          title = "Clear",
                          action = function(button)
                             props.search_similar_images = {}
                             props.similar_photo = nil
                             props.similar_total = ""
                          end
                       },
                       f:push_button {
                          title = "Add Selected",
                          action = function(button)
                             props.similar_checkbox = true
                             local catalog = LrApplication.activeCatalog()
                             local photos = catalog:getTargetPhotos()
                             local photo = catalog:getTargetPhoto()
                             if photo ~= nil then
                                props.search_similar_images = utils.appendTable(props.search_similar_images,photos)
                             end
                             
                             if #props.search_similar_images > 1 then
                                props.similar_total = string.format("+ %d",#props.search_similar_images - 1)
                             end

                             if props.similar_photo == nil then
                                props.similar_photo = catalog:getTargetPhoto()
                             end
                          end
                       }
                    }
                 }
              },
              f:column {
                 f:spacer {
                    height = 48
                 },
                 f:push_button {
                    title = "< >",
                    action = function(button)
                       local temp = props.search_similar_images
                       props.search_similar_images = props.search_dissimilar_images
                       props.search_dissimilar_images = temp

                       temp = props.similar_photo
                       props.similar_photo = props.dissimilar_photo
                       props.dissimilar_photo = temp

                       temp = props.similar_total
                       props.similar_total = props.dissimilar_total
                       props.similar_total = temp

                       props.similar_factor = -props.similar_factor
                    end
                 }
              },
              f:column {
                 f:checkbox {
                    value = LrView.bind("dissimilar_checkbox"),
                    title = "Dissimilar to images:",
                 },
                 f:column {
                    f:row {
                       f:spacer {
                          width = 16
                       },
                       f:column {
                          f:catalog_photo {
                             photo = LrView.bind("dissimilar_photo"),
                             width = 64,
                             height = 64
                          },
                          f:static_text {
                             title = LrView.bind("dissimilar_total")
                          },
                       }
                    },
                    f:row {
                       f:push_button {
                          title = "Clear",
                          action = function(button)
                             props.search_dissimilar_images = {}
                             props.dissimilar_photo = nil
                             props.dissimilar_total = ""
                          end
                       },
                       f:push_button {
                          title = "Add Selected",
                          action = function(button)
                             props.dissimilar_checkbox = true
                             local catalog = LrApplication.activeCatalog()
                             local photos = catalog:getTargetPhotos()
                             local photo = catalog:getTargetPhoto()
                             if photo ~= nil then
                                props.search_dissimilar_images = utils.appendTable(props.search_dissimilar_images,photos)
                             end
                             if #props.search_dissimilar_images > 1 then
                                props.dissimilar_total = string.format("+ %d",#props.search_dissimilar_images - 1)
                             end
                             if props.dissimilar_photo == nil then
                                props.dissimilar_photo = catalog:getTargetPhoto()
                             end
                          end
                       }
                    }
                 }
              }              
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 fill_horizontal = 0.5,
                 f:checkbox {
                    title = "Clear Cache",
                    value = LrView.bind("force_load_checkbox")
                 }
              },
              f:static_text {
                 title = "Filter"
              },
              
              f:static_text {
                 title = "Less"
              },
              f:slider {
                 value = LrView.bind("similar_factor"),
                 min = -50,
                 max = 50.0
              },
              f:static_text {
                 title = "More"
              },
              f:column {
                 fill_horizontal = 0.5
              }
           },
           f:group_box {
              fill_horizontal = 1.0,
              title = "Attributes",
              f:row {
                 fill_horizontal = 1.0,
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Image assessment >",
                          value = LrView.bind("nima_checkbox")
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("nima_min"),
                          placeholder_string = "0-10.0",
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("nima_max"),
                          placeholder_string = "0-10.0",
                       }
                    }
                 },
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Aspect Ratio >",
                          value = LrView.bind("aspect_checkbox")
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("aspect_min"),
                          placeholder_string = "1.0",
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("aspect_max"),
                          placeholder_string = "1.0",
                       }
                    }
                 }
              },
              f:row {
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "People Detected >",
                          value = LrView.bind("people_checkbox")
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("people_min"),
                          placeholder_string = "0",
                       }
                    }
                 },
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Faces Detected >",
                          value = LrView.bind("faces_checkbox")
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("faces_min"),
                          placeholder_string = "0",
                       },
                    }
                 }
              },
              f:row {
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Hue Mean (deg)>",
                          value = LrView.bind("huemean_checkbox")
                       },
                       f:color_well {
                          value =  LrView.bind("huemean_min_color")
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("huemean_min_color_x_visible"),
                          action = function()
                             props.huemean_min_color = LrColor()
                             props.huemean_min_color_x_visible = false
                          end
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:color_well {
                          value = LrView.bind("huemean_max_color"),
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("huemean_max_color_x_visible"),
                          action = function()
                             props.huemean_max_color = LrColor()
                             props.huemean_max_color_x_visible = false
                          end
                       },
                    }
                    
                 },
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Hue StdDev (deg) >",
                          value = LrView.bind("huestd_checkbox")
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("huestd_min"),
                          placeholder_string = "0-360",
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:edit_field {
                          width_in_chars = 4,
                          value = LrView.bind("huestd_max"),
                          placeholder_string = "0-360",
                       }
                    }
                 }
              },              
              f:row {
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Brightness (0-1) >",
                          value = LrView.bind("brightness_checkbox")
                       },
                       f:color_well {
                          value = LrView.bind("brightness_min_color"),
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("brightness_min_color_x_visible"),
                          action = function()
                             props.brightness_min_color = LrColor()
                             props.brightness_min_color_x_visible = false
                          end
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:color_well {
                          value = LrView.bind("brightness_max_color"),
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("brightness_max_color_x_visible"),
                          action = function()
                             props.brightness_max_color = LrColor()
                             props.brightness_max_color_x_visible = false
                          end
                       },
                    }
                 },
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "Saturation (0-1) >",
                          value = LrView.bind("saturation_checkbox")
                       },
                       f:color_well {
                          value = LrView.bind("saturation_min_color"),
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("saturation_min_color_x_visible"),
                          action = function()
                             props.saturation_min_color = LrColor()
                             props.saturation_min_color_x_visible = false
                          end
                       },
                       f:static_text {
                          title = "or < "
                       },
                       f:color_well {
                          value = LrView.bind("saturation_max_color"),
                       },
                       f:push_button {
                          title = "X",
                          visible = LrView.bind("saturation_max_color_x_visible"),
                          action = function()
                             props.saturation_max_color = LrColor()
                             props.saturation_max_color_x_visible = false
                          end
                       }
                    }
                 }
              },
              f:row {
                 f:column {
                    fill_horizontal = 0.5,
                    f:row {
                       f:checkbox {
                          title = "NSFW",
                          value = LrView.bind("nsfw_checkbox")
                       },
                       f:popup_menu {
                          value = LrView.bind("nsfw"),
                          items = {
                             { title = "true",
                               value = true },
                             { title = "false",
                               value = false }
                          }
                       }
                    }
                 },
                 f:column {
                 }
              },
           },
           
           f:row {
              f:static_text {
                 title = "Output Collection:"
              },
              f:edit_field {
                 value = LrView.bind("output_collection"),
                 validate = function(view,val)
                    return string.len(val) > 0, val, ""
                 end
              },
              f:checkbox {
                 title = "Append",
                 value = LrView.bind("collection_append")
              }
           },
           f:row {
              fill_horizontal = 1.0,
              f:column {
                 fill_horizontal = 1.0
              },
              f:static_text {
                 title = LrView.bind("status_text"),
                 truncation = "middle",
                 width_in_chars = 20
              },
              f:push_button {
                 title = "Cancel",
                 visible = LrView.bind("cancel_visible"),
                 action = function(button)
                    props.cancel = true
                 end
              },                    
              f:push_button {
                 title = "Search",
                 enabled = LrView.bind("search_enabled"),
                 action = function(button)
                    props.search_enabled = false
                    props.cancel_visible = true
                    props.cancel = false
                    LrFunctionContext.postAsyncTaskWithContext("processSearch",
                                                               doSearch)
                 end
              }
                       
           }                            
        }

        LrTasks.startAsyncTask(function()
              fetchTrees()
              utils.fetchCollections(function(collections,sets)
                    props.collection_values = utils.prepCollections(collections)
                    props.set_values = utils.prepCollectionSets(sets)
              end)
              LrDialogs.presentFloatingDialog(_PLUGIN, {
                 title = "CrossPrism Search",
                 contents = c,
                 blockTask = true,
                 onShow = function()
                    log:trace( "in onShow" )
                 end,
                 windowWillClose = function()
                    prefs['search_output_collection'] = props.output_collection
                    prefs['search_collection_append'] = props.collection_append
                    log:trace( "window will close" )
                    props.cancel = true
                    floatingWillClose = true
                 end,
              })

        end)

        --neccessary or else some of the listeners get otherwise deallocated 
        while not floatingWillClose do
           -- LrTasks.startAsyncTask(checkSelectedPhoto)
           LrTasks.sleep (1.0)
        end
	end) -- end main function
end

-- Now display the dialogs.
showCustomDialog()


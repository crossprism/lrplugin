-- Shared functions for CrossPrism Lightroom Plugin
--

local LrApplication = import 'LrApplication'
local LrShell = import 'LrShell'
local LrDialogs = import 'LrDialogs'
local JSON = require 'JSON.lua'
local LrHttp = import 'LrHttp'
local LrView = import 'LrView'
local LrLogger = import 'LrLogger'
local LrTasks = import 'LrTasks'

local mime = require 'mime.lua'

M = {}

local f = LrView.osFactory()
local check_columns = 4
local check_rows = 10
local log = LrLogger( 'ClassificationDialog' )

function trim(s)
   return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.trim(s)
   return trim(s)
end


local function csvToTableKeys(body)
   local retVal = {}
   for word in body:gmatch("[^,]+") do
      retVal[string.lower(trim(word))] = ""
   end
   return retVal
end

function M.csvToTableKeys(body)
   return csvToTableKeys(body)
end

function csvToTable(body)
   local retVal = {}
   if body ~= nil then
      for word in body:gmatch("[^,]+") do
         retVal[#retVal + 1] = string.lower(trim(word))
      end
   end
   return retVal
end

function M.csvToTable(body)
   return csvToTable(body)
end

local function isarray(t)
  return #t > 0 and next(t, #t) == nil
end

local function tableToString(t)
   local retVal = ""
   if isarray(t) then
      for i,v in ipairs(t) do
         if i ~= 1 then
            retVal = retVal .. ","
         end
         retVal = retVal .. tostring(v)
      end
   else
      local i = 0
      for k,v in pairs(t) do
         if i ~= 0 then
            retVal = retVal .. ","
         end
         retVal = retVal .. k .. ":" .. tostring(v)
         i = i + 1
      end
   end
   return retVal         
end

function M.tableToString(t)
   return tableToString(t)
end

-- For small tables which we don't want to bother converting to key-value
function M.tableContains(t,subject)
   for i,value in ipairs(t) do
      if value == subject then
         return true
      end
   end
   return false
end

function M.appendTable(t1,t2)
   for i,v in ipairs(t2) do
      if v ~= nil then
         t1[#t1+1] = v
      end
   end
   return t1
end

function M.mergeCSV(s1,s2)
   s1 = csvToTableKeys(s1)
   s2 = csvToTableKeys(s2)
   for k,v in pairs(s2) do
      s1[k] = v
   end
   local result = {}
   for k,v in pairs(s1) do
      result[#result+1] = k
   end
   return tableToString(result)
end


function M.RGBToHSV( red, green, blue )
	-- Returns the HSV equivalent of the given RGB-defined color
	-- (adapted from some code found around the web)

	local hue, saturation, value;

	local min_value = math.min( red, green, blue );
	local max_value = math.max( red, green, blue );

	value = max_value;

	local value_delta = max_value - min_value;

	-- If the color is not black
	if max_value ~= 0 then
		saturation = value_delta / max_value;

	-- If the color is purely black
	else
		saturation = 0;
		hue = -1;
		return hue, saturation, value;
	end;

	if red == max_value then
		hue = ( green - blue ) / value_delta;
	elseif green == max_value then
		hue = 2 + ( blue - red ) / value_delta;
	else
		hue = 4 + ( red - green ) / value_delta;
	end;

	hue = hue * 60;
	if hue < 0 then
		hue = hue + 360;
	end;

	return hue, saturation, value;
end;

function M.sortTableByValue(t)
   local temp = {}
   for key,val in pairs(t) do
      temp[#temp + 1] = {key,val}
   end
   table.sort(temp,function(a,b)
                 return a[2] > b[2]
   end)
   return temp
end

function M.clearCache(photos,callback)
   local catalog = LrApplication.activeCatalog()
   catalog:withPrivateWriteAccessDo(function()            
         for i,photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN,'features',nil)
            photo:setPropertyForPlugin(_PLUGIN,'features_extractor',nil)
            photo:setPropertyForPlugin(_PLUGIN,'extended_attributes',nil)
            if callback ~= nil then
               callback(i)
            end
         end
   end, {timeout = 1})
end

function reportNoService(baseUrl)
   if string.find(baseUrl,'/localhost') then
      local result = LrDialogs.confirm("Service not running",
                                       "Attempt to locally launch CrossPrism?","Launch")
      if result == "ok" then
         LrShell.openPathsViaCommandLine({"crossprism://start"},"/usr/bin/open","")
      end
      
   else
      LrDialogs.message("No response from service at "..baseUrl,"Please manually launch CrossPrism","critical")
   end
end

M.reportNoService = reportNoService

function M.loadTrees(baseUrl)
   local result, hdrs = LrHttp.get( baseUrl.."/trees",nil, 5)
   if result == nil then
      reportNoService(baseUrl)
   else
      local lua_value = JSON:decode(result)
      local keyset = {}
      local treeDict = {}

      for i,tuple in ipairs(lua_value) do
         treeDict[tuple[1]] = tuple[2]
         keyset[#keyset+1] = tuple[1]
      end
      return {treeDict, keyset}
   end
end

function M.loadTrainers(baseUrl,checkService)
   local result, hdrs = LrHttp.get( baseUrl.."/trainers",nil,5)
   if checkService and result == nil then
      reportNoService(baseUrl)
   end
   if result ~= nil then
      local lua_value = JSON:decode(result)
      local keyset = {}
      trainers = lua_value        
      for k,v in pairs(trainers) do
         keyset[#keyset+1]=k
      end
      return {trainers, keyset}
   end
end

function M.loadScreeners(baseUrl)
   local result, hdrs = LrHttp.get( baseUrl.."/screeners",nil,5)
   if result == nil then
      reportNoService(baseUrl)
   else
      local lua_value = JSON:decode(result)
      local keyset = {}
      trainers = lua_value        
      for k,v in pairs(trainers) do
         keyset[#keyset+1]=k
      end
      return {trainers, keyset}
   end
end


function overCheckboxes(f)
   for i = 1, check_rows do
      for j = 1, check_columns do
         f(j,i)
      end
   end
end

function overCheckboxLabels(props,f)
   overCheckboxes(function(j,i)
         local result = f(j,i)
         props["training_label_title_" .. i .. "_" .. j] = result[1]
         props["training_label_value_" .. i .. "_" .. j] = result[2]
         props["training_label_visible_" .. i .. "_" .. j] = result[3]
   end)
   return props
end

function M.initCheckboxLabels(props)
   return overCheckboxLabels(props,function(j,i)
      -- Reserve text size because it won't change after its created.
         return { "---------------",false,false}
   end)
end

function M.getCheckmarkLabels(props)
   local labels = {}
   overCheckboxes(function(j,i)
         if props["training_label_value_" .. i .. "_" .. j] then
            labels[#labels+1] = props["training_label_title_" .. i .. "_" .. j]
         end
   end)
   return tableToString(labels)
end


function trim(s)
   return (s:gsub("^%s*(.-)%s*$", "%1"))
end
function M.trim(s)
   return trim(s)
end

function normalize(keyword)
   local i,j
   i,j = keyword:find("<")
   if i ~= nil then
      keyword = trim(keyword:sub(1,i-1))
   else
      keyword = trim(keyword)
   end
   return keyword
end

function M.normalize(keyword)
   return normalize(keyword)
end

function filterExisting(e,filter)
   if filter == nil then
      return e
   end
   local filterComponents = csvToTableKeys(filter)
   local bodyComponents = csvToTable(e)
   local normlizedKeyword
   retVal = {}
   for i,v in ipairs(bodyComponents) do
      normalizedKeyword = normalize(v)
      if filterComponents[normalizedKeyword] == nil then
         retVal[#retVal + 1] = normalizedKeyword
      end
   end
   return table.concat(retVal,",")
end

function M.filterExisting(e,filter)
   return filterExisting(e,filter)
end

function updateCheckboxLabels(props)
   local labelIndex = 1
   local label, isVisible, isChecked
   local training = filterExisting(props.training_labels,props.filter_training)
   local labels = props.trainer_existing_table
   training = csvToTableKeys(training)
   
   props = overCheckboxLabels(props,function(j,i)
         if labelIndex <= #labels then
            label = labels[labelIndex]
            isVisible = true
            if training[label] ~= nil then
               isChecked = true
            else
               isChecked = false
            end
            labelIndex = labelIndex + 1
         else
            label = "-"
            isVisible = false
            isChecked = false
         end
         return {label,isChecked,isVisible}
   end)
   return props
end

function M.updateCheckboxLabels(props)
   return updateCheckboxLabels(props)
end

function M.initCheckboxRows(props)
   local rows = {}
   for i = 1, check_rows do
      local columns = {}
      for j = 1, check_columns do
         columns[#columns + 1] = f:checkbox {
            title = LrView.bind("training_label_title_" .. i .. "_" .. j),
            value = LrView.bind("training_label_value_" .. i .. "_" .. j),
            visible = LrView.bind("training_label_visible_" .. i .. "_" .. j)
         }
      end
      rows[#rows+1] = f:row(columns)
   end
   return rows
end

function M.trainerChange(trainers,value,props)
   local existing = trainers[value]['labels']
   local type = trainers[value]['type']
   local fixed = trainers[value]['fixed']
   log:trace("trainer: "..tableToString(existing))
   
   local result = ''
   if existing ~= nil then
      for i,v in pairs(existing) do
         if i > 1 then
            result = result..", "
         end
         result = result..v
      end
      props.trainer_existing_labels = result
      props.trainer_existing_table = existing
      if #existing > 0 then
         props.training_checkboxes_visible = true
         props = updateCheckboxLabels(props)
      else
         props.training_checkboxes_visible = false
      end
      props.training_labels_visible = not fixed
   end
   return props
end

function M.postTrain(baseUrl, trainerid, images)
   log:trace( "posting multipart mime" )
   local content_type,mencoded = mime.encode(images)
   headers = {
      { field = 'Content-type',
        value = content_type
      }
   }
   if string.len(trainerid) > 0 then
      headers[#headers + 1] = { field = 'X-Classifier-Module',
                                value = trainerid
      }
   end
   local result, hdrs = LrHttp.post( baseUrl.."/train", mencoded,
                                     headers )
end

function M.postScreenerSend(baseUrl, screener, images)
   local content_type,mencoded = mime.encode(images)
   headers = {
      { field = 'Content-type',
        value = content_type
      }
   }

   headers[#headers + 1] = { field = 'X-Classifier-Screener',
                             value = screener
   }

   local result, hdrs = LrHttp.post( baseUrl.."/screener", mencoded,
                                     headers )
end

function M.screenerSync(baseUrl, screener)
   headers = {
      { field = 'X-Classifier-Screener',
        value = screener
      }
   }

   local result, hdrs = LrHttp.get( baseUrl.."/screener",
                                    headers )
   if result ~= nil then
      return JSON:decode(result)
   end
end

function M.fetchCollections(callback)
   LrTasks.startAsyncTask(function()
         local catalog = LrApplication.activeCatalog()
         local collections = catalog:getChildCollections()
         local colset = {}
         for k,v in ipairs(collections) do
            colset[#colset + 1] = {
               title = v:getName(),
               value = v.localIdentifier
            }
         end
         local collection_values = colset
         colset = {}
         collections = catalog:getChildCollectionSets()
         for k,v in ipairs(collections) do
            colset[#colset + 1] = {
               title = v:getName(),
               value = v
            }
         end
         callback(collection_values, colset)
   end)
end

function M.jsonPhotoMeta(photo)
   local keys = {"path","rating","shutterSpeed","flash","isoSpeedRating","focalLength","dateTime","gps","gpsAltitude"}
   local jsonDict = {}
   for i,key in ipairs(keys) do
      -- log:tracef("attempting key: %s",key)
      local val = photo:getRawMetadata(key)
      if val ~= nil then
         jsonDict[key] = val
      end
   end
   return JSON:encode(jsonDict)
end

function M.fetchKeywords(callback) 
   LrTasks.startAsyncTask(function()
         local catalog = LrApplication.activeCatalog()
         local keywords = catalog:getKeywords()
         local finalKeywords = {}
         local objects = {}
         for i,v in ipairs(keywords) do
            finalKeywords[#finalKeywords + 1] = v:getName()
         end
         callback(finalKeywords)
   end)
end

function mysplit(inputstr,sep)
      if sep == nil then
      sep = "%s"
   end
   local t={}
   for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
      table.insert(t, str)
   end
   return t
end

function M.mysplit (inputstr, sep)
   return mysplit(inputstr,sep)
end

function M.addMetadata(photo,keywords,filter,parentKeywordId, title, description)
   local catalog = LrApplication.activeCatalog()
   log:trace("in addMetadata")
   if keywords ~= nil then
      labels = filterExisting(keywords,filter)
      labels = mysplit(labels,",")
   end
   LrTasks.startAsyncTask(
      function()
         catalog:withWriteAccessDo("Apply Keyword",
                                   function(context)
                                      log:trace("in write access")
                                      local parentKeyword = nil
                                      if keywords ~= nil then
                                         if parentKeywordId ~= nil and trim(parentKeywordId) ~= "" then
                                            parentKeyword = catalog:createKeyword(trim(parentKeywordId),{},false,nil,true)
                                         end
                                         for _,label in pairs(labels) do
                                            local keyword = catalog:createKeyword(trim(label:lower()),{},true,parentKeyword,true)
                                            photo:addKeyword(keyword)
                                         end
                                      end
                                      if title ~= nil then
                                         photo:setRawMetadata('title',title)
                                      end
                                      if description ~= nil then
                                         photo:setRawMetadata('caption',description)
                                      end
                                      log:trace("set metadata")
         end)
   end)
end

function M.default(value, def)
   if value == nil then
      return def
   end
   return value
end

function M.defaultNumber(value, def)
   local newval = tonumber(value)
   if newval == nil then
      return def
   end
   return newval
end


function M.prepSubtrees(subtrees)
   local noNull = subtrees[1] ~= '-'
   table.sort(subtrees)
   if #subtrees < 1 or noNull then
      table.insert(subtrees,1,'-')
   end
   return subtrees
end

function M.prepTrees(trees)
   table.sort(trees)
   return trees
end

function M.prepTrainers(trainers)
   table.sort(trainers)
   return trainers
end

function M.prepCollections(collections)
   table.sort(collections,function(a,b)
                 return a.title < b.title
   end)
   return collections
end

function M.prepCollectionSets(sets)
   table.sort(sets,function(a,b)
                 return a.title < b.title
   end)
   return sets
end

-- This scales using the shortest dimension instead of the longest.
-- It ensures that the smallest dimension can satisfy the max input of
-- ML models which typically perform fill stretch to maximize input information.
function squareUsingShortSide(photo,xMax,yMax)
   local dims = photo:getRawMetadata("croppedDimensions")
   if dims["width"] > dims["height"] then
      scale = yMax/dims["height"]
      return dims["width"] * scale
   else
      scale = xMax/dims["width"]
      return dims["height"] * scale
   end
end

function M.maxDimUsingShortSide(photo, max)
   return squareUsingShortSide(photo,max,max)
end

return M

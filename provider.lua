local LrApplication = import 'LrApplication'
local LrView = import 'LrView'
local prefs = import 'LrPrefs'.prefsForPlugin()
local utils = require 'utils.lua'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrLogger = import 'LrLogger'
local log = LrLogger( 'Provider' )

local logging_method = "print"

log:enable( { fatal = logging_method,
              error = logging_method,
              warn = logging_method,
              info = logging_method,
              debug = logging_method,
              trace = logging_method,
} )


sectionsForTopOfDialog = function( viewFactory, propertyTable)
   local f = viewFactory
   local server_url = propertyTable['server_url']
   local statusTable = {
      temp_cache_status = ""
   }   
   if server_url == nil or #server_url == 0 then
      propertyTable['server_url'] = "http://localhost:9000"
   end
   if propertyTable['use_cache'] == nil then
      propertyTable['use_cache'] = false
   end
   return {
      {
         title = "Settings",
         synopsis = "General settings for the plugin",
         f:group_box {
            title = "Setup",
            fill_horizontal = 1.0,
            bind_to_object = propertyTable,
            f:row {
               fill_horizontal = 1.0,
               f:static_text {
                  title = "Classifier URL"
               },
               f:edit_field {
                  fill_horizontal = 1.0,
                  immediate = true,
                  height_in_lines = 1,
                  value = LrView.bind( "server_url" ),
                  enabled = true
               },
            },
            f:row {
               fill_horizontal = 1.0,
               f:checkbox {
                  title = "Send existing keywords as hints",
                  value = LrView.bind( "send_hints" )
               },
               f:static_text {
                  title = "Timeout"
               },
               f:edit_field {
                  width_in_chars = 5,
                  value = LrView.bind("timeout"),
                  placeholder_string = "seconds"
               }
            },
            f:row {
               f:checkbox {
                  title = "Use Cache",
                  value = LrView.bind( "use_cache" )
               },
               f:push_button {
                  title = "Clear Cache",
                  action = function(button)
                     local handler = function(context)
                        context:addCleanupHandler(function()
                        end)
                        context:addFailureHandler(function(status,msg)
                              log:errorf("Failed during clear cache: %s",msg)
                        end)
                        local catalog = LrApplication.activeCatalog()
                        log:tracef("Got catalog %s",catalog)
                        local photos = catalog:getAllPhotos()
                        local total = #photos
                        log:tracef("Got photos %d", total)
                        utils.clearCache(photos,function(index)
                                            if index == total then
                                               statusTable.temp_cache_status = "done"
                                            else
                                               statusTable.temp_cache_status = string.format("%d/%d",index,total)
                                            end
                                            
                                            LrTasks.yield()
                        end)
                        log:trace("finished clearing")
                     end
                     LrFunctionContext.postAsyncTaskWithContext( "CrossPrismProvider", handler)
                  end
               },
               f:static_text {
                  title = LrView.bind("temp_cache_status",statusTable)
               }
            }
         }
      }
   }
end

return {
   startDialog = function(propertyTable)
      for i,j in pairs(prefs) do
         propertyTable[i] = j
         log:tracef("Loading from prefs: %s %s",i,j)
      end
   end,
   endDialog = function(propertyTable)
      for i,j in pairs(propertyTable) do
         log:tracef("enddialog: %s (%s) - %s",i,type(i),j)
         if type(i) == "string" then
            pos,len = string.find(i,'temp_')
            if pos ~= 1 then
               prefs[i] = j
               log:tracef("saving %s",i)
            else
               prefs[i] = nil
               log:tracef("skipping saving %s",i)
            end
         end
      end
   end,
   sectionsForTopOfDialog = sectionsForTopOfDialog,
}

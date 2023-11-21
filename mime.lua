local base64 = require 'base64.lua'

M = {}

local function generateBoundary()
   local prefix = "clsPfxBdry"
   for _=0,6 do
      prefix = prefix .. base64.enc(string.char(math.floor(math.random() * 255)))
   end
   return prefix
end

function M.encode(images)
   local body = ''
   local boundary = generateBoundary()
   body = string.format('Content-type: multipart/mixed; boundary="%s"\r\n\r\n',boundary)
   for _,image in pairs(images) do
      body = body .. string.format("--%s\r\n", boundary)
      body = body .. string.format("Content-type: image/jpeg\r\n")
      body = body .. string.format("Content-Transfer-Encoding: BASE64\r\n")
      if image.labels ~= nil then
         body = body .. string.format("X-Classifier-Labels: %s\r\n",image.labels)
      end
      if image.id ~= nil then
         body = body .. string.format("X-Classifier-ID: %s\r\n",image.id)
      end

      if image.name ~= nil then
         body = body .. string.format("X-Classifier-Name: %s\r\n",image.name)
      end
      if image.json ~= nil then
         body = body .. string.format("X-Classifier-Json: %s\r\n",image.json)
      end
      body = body .. "\r\n"
      
      local b64Image = base64.enc(image.image)
      body = body .. b64Image .."\r\n"
   end
   body = body .. string.format("--%s--\r\n",boundary)
   
   return 'multipart/mixed; boundary="' .. boundary .. '"',body
end

return M

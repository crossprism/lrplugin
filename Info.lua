--[[----------------------------------------------------------------------------

ADOBE SYSTEMS INCORPORATED
 Copyright 2007 Adobe Systems Incorporated
 All Rights Reserved.

NOTICE: Adobe permits you to use, modify, and distribute this file in accordance
with the terms of the Adobe license agreement accompanying it. If you have received
this file from a source other than Adobe, then your use, modification, or distribution
of it requires the prior written permission of Adobe.

--------------------------------------------------------------------------------

Info.lua
Summary information for Hello World sample plug-in.

Adds menu items to Lightroom.

------------------------------------------------------------------------------]]

return {
	
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 6.0, -- minimum SDK version required by this plug-in

	LrToolkitIdentifier = 'com.excelsis.crossprism',

	LrPluginName = LOC "$$$/CrossPrism/PluginName=CrossPrism",
	LrPluginInfoProvider = "provider.lua",
	
	-- Add the menu item to the Library menu.
	
	LrLibraryMenuItems = {
       {
		    title = LOC "$$$/CrossPrism/CustomDialog=Photo Classifier",
		    file = "SingleDialog.lua",
		},
        {
		    title = LOC "$$$/CrossPrism/SearchDialog=Photo Search",
		    file = "SearchDialog.lua",
		},
        {
		    title = LOC "$$$/CrossPrism/SearchDialog=Photo Trainer",
		    file = "TrainerDialog.lua",
		},
        {
		    title = LOC "$$$/CrossPrism/SearchDialog=Photo Screener",
		    file = "ScreenerDialog.lua",
		},

	},
	VERSION = { major=1, minor=0, revision=0, build="1.0.0-000001", },
    LrMetadataProvider = "metadata.lua",

}


	

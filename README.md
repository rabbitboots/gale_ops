
# GaleOps

A LÖVE module for reading GraphicsGale image (Gale) files.


## Purpose

Provides a way to convert Gale images to sets of LÖVE ImageData, to be modified and written back out to disk. While you could use it to load and display animations in a LÖVE game at run-time, it is really intended to be part of a build system.


## Usage

Gale files are fairly straightforward to parse, but rendering more than one layer is not. Several things factor into how the final image is displayed. A demo LÖVE application is provided which loads and plays a full looping animation.

Usage generally goes like this:

* Create a File object pointing to the .gal you want to load. Open it in binary read mode ("r").
* Create a bare GaleImage with galeOps.loadSkeleton(). The file header will be loaded and parsed, but no subsequent data blocks will be loaded. Instead, the block offsets and byte-lengths are stored in the layer tables.
* Either load specific layers with galeOps.populateLayer(), or load all layers at once with galeOps.populateAllLayers().
* Either make specific LÖVE ImageDatas with galeOps.makeImageData(), or convert all layers at once with galeOps.makeImageDataAll().
* Close the File object, and continue on with the converted ImageData objects.


GaleOps contains no functions to open, close (with the exception of fatal error cleanup) or write files. Functions expecting a File object require that it is already open in read mode ("r") before calling. Close the File object when you are done with it.
	
File methods used:
* File:read()
* File:seek()
* File:isOpen()
* File:getMode()
* File:close() (used in error scenarios)


## Supported Versions

GaleOps reads the 'GaleX200' file format. Support for older formats is missing. I believe GaleX200 was introduced in 2009.

		
## Missing Features / Nice-to-haves

* Cannot write Gale files.


## Issues

* I'm not sure if alpha channels are working correctly with my setup, under Wine. For example, indexed images with alpha channels just show 100% white.


## Other Limitations and Won't-Fix's:

* LÖVE ImageData objects don't support indexed palettes, so it's not possible to directly pass that info to converted ImageData objects. For indexed images, you can grab per-frame palettes from the GaleFrame tables.
* BGColor is stored but not hooked up in getPixel(). You can use galeOps.makeImageDataBGColor() to make an ImageData filled with the GaleImage's background color.
* Gale's 15bpp and 16bpp color depth modes appear to have some minor color component inconsistencies. (Convert a 24bpp Gale to 15bpp, then back and forth again. The 15bpp pixels are brighter.)
* Combining ImageData layers with partial transparency isn't 1:1 with how GraphicsGale does it.
* The special frame name '%framenumber%' is left as-is.


## Acknowledgements

Thanks to Heriet and Skarik for documentation on the Gale file format:

https://zenn.dev/heriet/articles/graphics-gale-image-format-structure (Japanese)
https://github.com/heriet/hxPixel/tree/master/hxpixel/images/gal
https://github.com/skarik/opengalefile/

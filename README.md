# galeOps

This is a LÖVE module for reading GraphicsGale image (Gale) files.


## Usage

While parsing a Gale image is fairly straightforward, there are some settings which affect how a multi-layer image appears. You will have to make some decisions on whether to respect or override those settings. An example LÖVE application is bundled which loads and plays a looping Gale image with multiple layers.

Usage generally goes like this:

* Create a File object pointing to the .gal you want to load. Open it in binary read mode (`"r"`).

* Create a bare GaleImage with `galeOps.loadSkeleton()`. The file header will be loaded and parsed, but no subsequent data blocks will be loaded. Instead, the block offsets and byte-lengths are stored in the layer tables.

* Either load specific layers with `galeOps.populateLayer()`, or load all layers at once with `galeOps.populateAllLayers()`. (For convenience, the second argument of `galeOps.loadSkeleton()` will also populate all layers.)

* Either make specific LÖVE ImageData objects with `galeOps.makeImageData()`, or convert all layers at once with `galeOps.makeImageDataAll()`.

* Close the File object.

From there, you can create LÖVE images to display at run-time, save the images back to disk as PNG, etc.


## Notes

GaleOps contains no functions to open, close (with the exception of fatal error cleanup) or write files. Functions expecting a File object require that it is already open in read mode (`"r"`) before calling. Close the File object when you are done with it.

File methods used:
* `File:read()`
* `File:seek()`
* `File:isOpen()`
* `File:getMode()`
* `File:close()` (error cleanup)


## Supported Versions

GaleOps reads the `GaleX200` file format. Support for older formats is not yet implemented. (I believe `GaleX200` was introduced in 2009.)


## Missing Features / Nice-to-haves

* Cannot write Gale files.


## Issues

* I'm not sure if alpha channels are working correctly with my setup, under Wine. For example, indexed images with alpha channels just show 100% white.


## Other Limitations and Probably-Won't-Fix's:

* LÖVE ImageData objects don't support indexed palettes, so it's not possible to directly pass that info to converted ImageData objects. For indexed images, you can grab per-frame palettes from the GaleFrame tables.

* BGColor is stored in the converted GaleImage table, but not used in `getPixel()`. You can use `galeOps.makeImageDataBGColor()` to make an ImageData filled with the background color.

* Gale's 15bpp and 16bpp color depth modes appear to have some minor color component inconsistencies. Convert a 24bpp Gale to 15bpp, then back and forth again. The 15bpp pixels are brighter. I've never seriously used 15bpp or 16bpp color modes, so I'm not sure if this is expected behavior or not.

* Combining ImageData layers with partial transparency isn't 1:1 with how GraphicsGale does it.

* The special interpolated frame name '%framenumber%' is left as-is.


## Design Notes

As a LÖVE library, only being able to read files directly from disk isn't the best design choice. This was originally a Python script, and some aspects of that original design have carried over.

Beyond that, I toyed with the idea of allowing the library user to load only specific layers from a Gale image. In theory, if the user was only interested in one specific layer, this would cut down on processing time. In practice, it's unnecessary and overcomplicated, as most Gale images aren't very big. It also prevents users from loading Gale images that are embedded in other data.

Loading a Gale image generates a fair bit of garbage: two binary strings for every data block (one compressed, one uncompressed). This isn't ideal, and a LÖVE-specific alternative should probably be investigated. My own use case is to convert Gale images to PNG as part of a build system, so that isn't a huge deal for me personally, but you probably wouldn't want to frequently load and unload Gale images in a game at run-time.


## Acknowledgements

Thanks to Heriet and Skarik for documentation on the Gale file format:

* https://zenn.dev/heriet/articles/graphics-gale-image-format-structure (Japanese)

* https://github.com/heriet/hxPixel/tree/master/hxpixel/images/gal

* https://github.com/skarik/opengalefile/

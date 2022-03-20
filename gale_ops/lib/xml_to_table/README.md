# xmlToTable

Converts a subset of XML to nested Lua tables.


## Usage Example

```lua
local xmlToTable = require("path.to.xml_to_table")

local lua_tree = xmlToTable.convert([[
<foobar>
 <element1 attr1="Hello" attr2="World">some text</element1>
 <empty_element />
</foobar>
]]
)

-- Look for the root element (it may not necessarily be lua_tree's first child,
-- as PIs can appear before the root tag.)
local root_element = lua_tree:getRootElement()

-- Find a child element by its name
local e1 = root_element:findChild("element1")

-- If found, print its attribute key="value" pairs
if e1 then
	for i, attrib in ipairs(e1.attribs) do
		print(i, attrib.name, attrib.value)
	end
end
--[[
1	attr1	Hello
2	attr2	World
--]]

-- Print the tree results for testing.
print(xmlToTable.dumpTree(lua_tree))
--[[
<foobar>
 <element1 attr1="Hello" attr2="World">
  some text
 </element1>
 <empty_element />
</foobar>
--]]
```

Note that larger XML files will result in very clunky tables. You can use this as an intermediate step, and construct a second table from it with the contents in the desired format.


## Public Functions

`xmlToTable.convert(xml_str)`: Attempts to convert `xml_str` to a nested Lua table.
* Returns: A parser root table. Failure to parse the string will raise a Lua error.

`xmlToTable.dumpTree(xml_tbl)`: *For debugging purposes.* Generates an XML-like string from a converted Lua table. The output may not be valid XML, and unlike `convert()`, no error checking is performed.


## Object Methods

NOTE: You may need to do some digging to identify what types of entities you have. The entity type is stored in its `id` field. The table returned by `xmlToTable.convert()` is always a Parser Root (it's not an XML construct, but it contains the final results from the parser.)

### The Parser Root (lua_tree)

`lua_tree:getElementRoot()`: Searches for the document root element. (`lua_tree.children[1]` may not contain the actual root, as some content such as Processing Instructions may appear before it.)
* Returns: the root element.

`lua_tree:findChild(id, [i])`: Searches for the first entity (element, processing instruction) with the name `id`, starting at index `i` *(default: 1)* in the parser root's list of children.
* Returns: the first result, or nil if no match was found.


### XML Elements

`element:getAttribute(key_id)`: Look for an attribute named `key_id` in this element, and return its value if found, or nil if it wasn't populated.

`element:findChild(id, [i])`: Searches for the first entity (element, processing instruction) with the name `id`, starting at index `i` *(default: 1)* in the element's list of children.
* Returns: the first result, or nil if no match was found.


### Text Nodes

`text_node:getText()`: Returns the text node's string content.


### Processing Instructions

`pi:getText()`: Returns the Processing Instruction's string content.


## Options

Some parsing options can be tweaked in `xmlToTable.options`. It is recommended to leave them as-is unless you have special requirements.

`options.prepass.doc_check_nul`: *(true)* Check the XML string for Nul bytes (0x0), which are forbidden by the spec.

`options.prepass.doc_check_xml_unsupported_chars`: *(true)* Check XML string for Unicode code points that are not supported per the spec.

`options.prepass.normalize_end_of_line`: *(true)* Convert 'carriage return + line feed' and 'carriage return' to just 'line feed', per the spec. One possible reason for disabling this: you control the incoming XML strings, and know for a fact that they are already normalized. (Doing this in Lua may generate up to two temporary versions of the XML document string.)

`options.validate_names`: *(true)* Confirm that XML Names conform to the spec's requirements. (Doesn't start with 0-9, etc.)

`options.check_dupe_attribs`: *(true)* Disallow multiple element attributes with the same name.

`options.keep_insignificant_whitespace`: *(false)* Keep character data entities which are comprised solely of whitespace between element tags. *NOTE: This option may not be working correctly (when true) and needs more testing.*


## Not Yet Supported

* The XML Declaration is parsed, but nothing is actually done with its contents yet.

* Document Type Declarations (DTDs / `<!DOCTYPE...>`) and XML Schemas. The parser will throw an error upon encountering a DTD tag.

* The `xml:space` special attribute.

* UTF-16 encoding. (The spec mandates it.)

* XML 1.1 features.


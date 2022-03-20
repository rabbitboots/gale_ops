local path = ... and (...):match("(.-)[^%.]+$") or ""

local xmlToTable = require(path .. "xml_to_table")

local errTest = require(path .. "test.lib.err_test")
local inspect = require(path .. "test.lib.inspect.inspect")


print("\n * PUBLIC FUNCTIONS * \n")


do
	local ok, result
	print("\nTest: " .. errTest.register(xmlToTable.convert, "xmlToTable.convert") ) -- (xml_str)
	print("\n[+] Expected behavior.")
	ok, result = errTest.expectPass(xmlToTable.convert, [[<?xml version="1.0" encoding="UTF-8"?><test_xml><empty_element/></test_xml>]])
	print(inspect(result))

	print("\n[-] empty document with no root node")
	ok, result = errTest.expectFail(xmlToTable.convert, "")

	print("\n[-] unbalanced element tags 1")
	ok, result = errTest.expectFail(xmlToTable.convert, [[<test><foo></foo><bar></bar>]]) -- no </test>

	print("\n[-] unbalanced element tags 2")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo></foo><bar></test>")

	print("\n[-] XMLDecl in wrong spot")
	ok, result = errTest.expectFail(xmlToTable.convert, "     <?xml <test><foo></foo>")

	print("\n[-] Incorrect PI tag close")
	ok, result = errTest.expectFail(xmlToTable.convert, "<?pi > <test><foo></foo>")
	
	print("\n[-] Incorrect comment close")
	ok, result = errTest.expectFail(xmlToTable.convert, "<!-- oo--ps --> <test><foo></foo>")
	ok, result = errTest.expectFail(xmlToTable.convert, "<!-- oo-s -> <test><foo></foo>")

	print("\n[-] Character Data after root close")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo></foo></test> asdf")
	
	print("\n[-] Element appears after root close")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo></foo></test><asdf />")
	
	print("\n[-] Bad escape")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo key='value&bad;'></foo></test>")
	
	print("\n[+] Good escapes")
	ok, result = errTest.expectPass(xmlToTable.convert, "<test><foo key='123&lt;123&gt;xxx&#33;&#x21;'></foo></test>")
	print(inspect(result))

	print("\n[-] !DOCTYPE not supported yet :( focusing on releasing galeOps right now")
	ok, result = errTest.expectFail(xmlToTable.convert, "<!DOCTYPE test><test><foo key='value&bad;'></foo></test>")

	print("\n[-] Unescaped '<' in quoted text")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo key='val<>ue'></foo></test>")

	print("\n[-] Space in element name")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><fo o key='value'></foo></test>")

	print("\n[-] Illegal characters in element name")
	local illegal_chars = {"!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "/", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "`", "{", "|", "}", "~", " ", "\n",}
	local illegal_start_chars = {"-", ".", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
	for i, char in ipairs(illegal_chars) do
		table.insert(illegal_start_chars, illegal_chars[i])
	end

	for i = 1, #illegal_start_chars do
		local illegal = illegal_start_chars[i]
		io.write("[" .. illegal .. "] ")
		ok, result = errTest.expectFail(xmlToTable.convert, "<test><" .. illegal .. "foo></foo></test>")
	end

	for i = 1, #illegal_chars do
		local illegal = illegal_chars[i]
		io.write("[" .. illegal .. "] ")
		if illegal == ">" then
			print("(skip '>': it leads to the second '>' being interpreted as character data, which is legal.)")
		elseif illegal == " " then
			print("(skip ' ': it could be used in a legal manner to separate an element name from attributes.")
		elseif illegal == "\n" then
			print("(skip newline)")
		else
			ok, result = errTest.expectFail(xmlToTable.convert, "<test><foo" .. illegal .. "></foo></test>")
		end
	end

	-- XXX check escape sequences in character data vs CDATA (where they shouldn't happen)
	
	print("\n[+] line feed in attribute value is discouraged but legal")
	ok, result = errTest.expectPass(xmlToTable.convert, "<test><foo key='va\nlue'></foo></test>")

	print("\n[-] ']]>' can't appear in plain character data")
	ok, result = errTest.expectFail(xmlToTable.convert, "<test><foobar>abcdefg]]></foobar></test>")

	print("\n[ad hoc] All whitespace symbols (ie line feed) in non-DTD'd attribute data should be swapped for space (0x20)")
	local xml_temp = xmlToTable.convert("<test attrib='\nv\na\r\nl\r\nu\ne\r'></test>")
	print(inspect(xml_temp))

---------------------------------------------------------------------------------------------------
	print("\n[+] insignificant whitespace should be omitted from the final tree")
	ok, result = errTest.expectPass(xmlToTable.convert, [[<?xml version="1.0" 
	encoding="UTF-8"?>
	<test_xml>
		<empty_element/>             
		         		
		         		
		         		
		         </test_xml>
		         
		       
]])
	print(inspect(result))
---------------------------------------------------------------------------------------------------
end


do
	local ok, result
	print("\nTest: " .. errTest.register(xmlToTable.dumpTree, "xmlToTable.dumpTree") ) -- (entity)
	
	print("\n[-] arg #1 bad type")
	ok, result = errTest.expectFail(xmlToTable.dumpTree, nil)
	
	print("\n[ad hoc] Expected behavior")
	local xml_tree = xmlToTable.convert([[
<?xml version="1.0" encoding="UTF-8"?>
<test>
	<child1 attr1="hello" attr2 = "world">foobar</child1>
	<child2 />
	<?foobar asdf?>
	<child3>
		<grandchild1 attr="something">raboof</grandchild1>
	</child3>
</test>
]])
	print(xmlToTable.dumpTree(xml_tree))
	
	print("\n[ad hoc] What happens if we pass an invalid table?")
	local what = xmlToTable.dumpTree({})
	print("|" .. what .. "|")
	-- Empty string, I guess.
end


do
	print("Test options.")
	print("options.prepass.doc_check_nul")
	
	-- NOTE: Even if this is set to false, XML parsing may still fail if the underlying UTF-8 code units
	-- are messed up.
	xmlToTable.options.prepass.doc_check_nul = true
	xmlToTable.options.prepass.doc_check_xml_unsupported_chars = false
	ok, result = errTest.expectFail(xmlToTable.convert, "<foo>\x00</foo>")

	print("options.prepass.doc_check_xml_unsupported_chars")
	xmlToTable.options.prepass.doc_check_xml_unsupported_chars = true
	xmlToTable.options.prepass.doc_check_nul = false
	ok, result = errTest.expectFail(xmlToTable.convert, "<foo>\x0C</foo>")
	
	xmlToTable.options.prepass.doc_check_nul = true

	-- Only set this to false if:
	-- 1) You control the incoming XML data
	-- 2) You know for a fact that it has already been end-of-line normalized.
	print("options.prepass.normalize_end_of_line")
	xmlToTable.options.prepass.normalize_end_of_line = false
	xmlToTable.convert("<foo>\r\n</foo>") -- uh oh

	xmlToTable.options.prepass.normalize_end_of_line = true

	-- Again, only do this if you're really confident about the incoming XML strings.
	print("options.validate_names")
	local bad_name = "<123invalidname>Oops</123invalidname>"
	local bad_name_mid = "<invalid\xD7name>Oops</invalid\xD7name>"
	ok, result = errTest.expectFail(xmlToTable.convert, bad_name)
	ok, result = errTest.expectFail(xmlToTable.convert, bad_name_mid)

	xmlToTable.options.validate_names = false
	local bad_tree = xmlToTable.convert(bad_name)
	print(inspect(bad_tree))
	
	xmlToTable.options.validate_names = true
	
	-- v1.0.1: Missed some problems with name validatation.
	local multi_byte_name = "<a123æÆŒœ321a>whoops</a123æÆŒœ321a>"
	ok, result = errTest.expectPass(xmlToTable.convert, multi_byte_name)
	print(inspect(result))

	print("options.check_dupe_attribs")
	ok, result = errTest.expectFail(xmlToTable.convert, "<foo dupe='one' dupe='two'></foo>")

	xmlToTable.options.check_dupe_attribs = false

	local dupe_table = xmlToTable.convert("<foo dupe='one' dupe='two'></foo>")
	print(inspect(dupe_table))

	xmlToTable.options.check_dupe_attribs = true

	print("options.ignore_bad_escapes")
	ok, result = errTest.expectFail(xmlToTable.convert, "<foo dupe='___&notarealescapesequence;___'></foo>")
	
	xmlToTable.options.ignore_bad_escapes = true
	
	print(inspect(xmlToTable.convert("<foo esc='___&notarealescapesequence;_huhwha&gt;tsgoingon__'></foo>")))
	
	xmlToTable.options.ignore_bad_escapes = false
	
	print("(Spooked by some issues with &; sequences, trying a few more to be safe.)")
	print(inspect(xmlToTable.convert("<foo esc='_&lt;_&gt;_&amp;_&quot;_&apos;_&#33;_&#x21;_'></foo>")))
	print(inspect(xmlToTable.convert("<foo esc='&lt;&gt;&amp;&quot;&apos;&#33;&#x21;'></foo>")))
	print(inspect(xmlToTable.convert("<foo esc='&amp;'></foo>")))

	print("options.keep_insignificant_whitespace")

	print(inspect(xmlToTable.convert("<foo>           <bar>   \n\n\n    </bar>    </foo>")))

	xmlToTable.options.keep_insignificant_whitespace = true
	
	print(inspect(xmlToTable.convert("<foo>           <bar>   \n\n\n    </bar>    </foo>")))
	
	xmlToTable.options.keep_insignificant_whitespace = false
end


local uiAvailable = app.isUIAvailable

local fileTypes = { "iff", "ilbm" }
local aspectResponses = { "BAKE", "SPRITE_RATIO", "IGNORE" }

local defaults = {
    aspectResponse = "SPRITE_RATIO"
}

---@param a integer
---@param b integer
---@return integer
local function gcd(a, b)
    while b ~= 0 do a, b = b, a % b end
    return a
end

---@param a integer
---@param b integer
---@return integer
---@return integer
local function reduceRatio(a, b)
    local denom <const> = gcd(a, b)
    return a // denom, b // denom
end

---@param importFilepath string
---@param aspectResponse "BAKE"|"SPRITE_RATIO"|"IGNORE"
---@return Sprite|nil
local function readFile(importFilepath, aspectResponse)
    local binFile, err = io.open(importFilepath, "rb")
    if err ~= nil then
        if binFile then binFile:close() end
        if uiAvailable then
            app.alert { title = "Error", text = err }
        else
            print(err)
        end
        return nil
    end

    if binFile == nil then
        if uiAvailable then
            app.alert {
                title = "Error",
                text = "File could not be opened."
            }
        else
            print(string.format("Error: Could not open file \"%s\".",
                importFilepath))
        end
        return nil
    end

    local block4 = 4
    local blockLen = block4
    local binData = binFile:read("a")
    binFile:close()

    local strfmt = string.format
    local strlower = string.lower
    local strsub = string.sub
    local strunpack = string.unpack
    local strbyte = string.byte

    local lenBinData = #binData

    local colorMode = ColorMode.INDEXED
    local widthImage = 0
    local heightImage = 0
    -- local xOrig = 0
    -- local yOrig = 0
    local planes = 0
    -- mskNone an opaque image
    -- mskHasMask
    -- mskHasTransparentColor
    -- mskLasso
    local masking = 0
    local compressed = 0
    local alphaIndex = 0
    local xAspect = 0
    local yAspect = 0
    local pageWidth = 0
    local pageHeight = 0

    ---@type Color[]
    local aseColors = {}

    ---@type integer[]
    local pixels = {}

    local cursor = 1
    while cursor <= lenBinData do
        local header = strsub(binData, cursor, cursor + 3)
        local headerlc = strlower(header)
        if headerlc == "form" then
            print("FORM found")
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenInt = strunpack(">I4", lenStr)
            print(strfmt("lenInt: %d", lenInt))
            blockLen = 8
        elseif headerlc == "ilbm" then
            print(strfmt("ILBM found. Cursor: %d", cursor))
            blockLen = 4
        elseif headerlc == "pbm " then
            print(strfmt("PBM found. Cursor: %d", cursor))
            blockLen = 4
        elseif headerlc == "bmhd" then
            print(strfmt("BMHD found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)

            local wStr = strsub(binData, cursor + 8, cursor + 9)
            local hStr = strsub(binData, cursor + 10, cursor + 11)
            widthImage = strunpack(">I2", wStr)
            heightImage = strunpack(">I2", hStr)
            print(strfmt("width: %d", widthImage))
            print(strfmt("height: %d", heightImage))

            -- local xOrigStr = strsub(binData, cursor + 12, cursor + 13)
            -- local yOrigStr = strsub(binData, cursor + 14, cursor + 15)
            -- xOrig = strunpack(">i2", xOrigStr)
            -- yOrig = strunpack(">i2", yOrigStr)
            -- print(strfmt("xOrigStr: %d", xOrig))
            -- print(strfmt("yOrigStr: %d", yOrig))

            local planesStr = strsub(binData, cursor + 16, cursor + 16)
            local maskStr = strsub(binData, cursor + 17, cursor + 17)
            local comprStr = strsub(binData, cursor + 18, cursor + 18)
            local reservedStr = strsub(binData, cursor + 19, cursor + 19)

            planes = strunpack(">I1", planesStr)
            masking = strunpack(">I1", maskStr)
            compressed = strunpack(">I1", comprStr)
            local reserved = strunpack(">I1", reservedStr)
            print(strfmt("planes: %d", planes))
            print(strfmt("masking: %d", masking))
            print(strfmt("compressed: %d", compressed))
            print(strfmt("reserved: %d", reserved))

            local trclStr = strsub(binData, cursor + 20, cursor + 21)
            local xAspStr = strsub(binData, cursor + 22, cursor + 22)
            local yAspStr = strsub(binData, cursor + 23, cursor + 23)
            alphaIndex = strunpack(">I2", trclStr)
            xAspect = strunpack(">I1", xAspStr)
            yAspect = strunpack(">I1", yAspStr)
            print(strfmt("alphaIndex: %d", alphaIndex))
            print(strfmt("xAspect: %d", xAspect))
            print(strfmt("yAspect: %d", yAspect))

            local pgwStr = strsub(binData, cursor + 24, cursor + 25)
            local pghStr = strsub(binData, cursor + 26, cursor + 27)
            pageWidth = strunpack(">I2", pgwStr)
            pageHeight = strunpack(">I2", pghStr)
            print(strfmt("pageWidth: %d", pageWidth))
            print(strfmt("pageHeight: %d", pageHeight))

            blockLen = 8 + lenLocal
        elseif headerlc == "cmap" then
            print(strfmt("CMAP found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            local numColors = lenLocal // 3
            print(strfmt("numColors: %d", numColors))
            local i = 0
            while i < numColors do
                local i3 = i * 3
                local r8 = strbyte(binData, cursor + 8 + i3)
                local g8 = strbyte(binData, cursor + 9 + i3)
                local b8 = strbyte(binData, cursor + 10 + i3)
                -- print(strfmt("%03d: %03d %03d %03d, #%06x",
                --     i, r8, g8, b8, r8 << 0x10 | g8 << 0x08 | b8))
                local aseColor = Color { r = r8, g = g8, b = b8, a = 255 }

                i = i + 1
                aseColors[i] = aseColor
            end

            blockLen = 8 + lenLocal
        elseif headerlc == "dpps" then
            -- Don't know what this is, but it's found in King Tut test image.
            print(strfmt("DPPS found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))
            blockLen = 8 + lenLocal
        elseif headerlc == "camg" then
            -- TODO: This needs to be parsed for ham, hires, etc.
            print(strfmt("CAMG found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))
            blockLen = 8 + lenLocal
        elseif headerlc == "ccrt" then
            -- TODO: Color Cycling Range and Timing. Test with WeatherMap image.

            --[[
            typedef struct {
            WORD  direction;    /* 0 = don't cycle.  1 = cycle forwards      */
            /* (1, 2, 3). -1 = cycle backwards (3, 2, 1) */
            UBYTE start, end;   /* lower and upper color registers selected  */
            LONG  seconds;      /* # seconds between changing colors plus... */
            LONG  microseconds; /* # microseconds between changing colors    */
            WORD  pad;          /* reserved for future use; store 0 here     */
            } CycleInfo;
            ]]
            print(strfmt("CCRT found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))
            blockLen = 8 + lenLocal
        elseif headerlc == "crng" then
            -- TODO: Color register range. Multiple chunks are likely.

            --[[
            typedef struct {
            WORD  pad1;      /* reserved for future use; store 0 here    */
            WORD  rate;      /* color cycle rate                         */
            WORD  flags;     /* see below                                */
            UBYTE low, high; /* lower and upper color registers selected */
            } CRange;
            ]]
            print(strfmt("CRNG found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))
            blockLen = 8 + lenLocal
        elseif headerlc == "tiny" then
            -- Chunk includes a thumbnail.
            print(strfmt("TINY found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            -- 9 instead of 8 is a fudge.
            blockLen = 9 + lenLocal
        elseif headerlc == "auth" then
            -- Chunk includes author information.
            print(strfmt("AUTH found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            blockLen = 8 + lenLocal
        elseif headerlc == "body" then
            print(strfmt("BODY found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            -- For decompression purposes, these bytes need to be signed?
            ---@type integer[]
            local bytes = {}
            local i = 0
            while i < lenLocal do
                i = i + 1
                -- For signed byte.
                -- bytes[i] = strunpack(">i1", strsub(binData, cursor + 7 + i))

                -- For unsigned byte.
                bytes[i] = strbyte(binData, cursor + 7 + i)
            end

            if compressed == 1 then
                print("Decompressing image.")

                ---@type integer[]
                local decompressed = {}

                local j = 0
                while j < lenLocal do
                    local byte = bytes[1 + j]
                    local readStep = 1
                    if byte > 128 then
                        local next = bytes[2 + j]
                        readStep = 2
                        local k = 0
                        while k < (257 - byte) do
                            decompressed[#decompressed + 1] = next
                            k = k + 1
                        end
                    elseif byte < 128 then
                        local k = 0
                        while k < (byte + 1) do
                            decompressed[#decompressed + 1] = bytes[2 + j + k]
                            k = k + 1
                            readStep = readStep + 1
                        end
                    end

                    j = j + readStep
                end

                bytes = decompressed
                print(strfmt("lenDecompressed: %d", #bytes))
            end

            ---@type integer[]
            local words = {}
            local lenBytes = #bytes
            local j = 0
            while j < lenBytes do
                local j_2 = j // 2
                -- For signed byte.
                -- local ubyte1 = bytes[1 + j] & 0xff
                -- local ubyte0 = bytes[2 + j] & 0xff

                -- For unsigned byte.
                local ubyte1 = bytes[1 + j]
                local ubyte0 = bytes[2 + j]

                words[1 + j_2] = ubyte1 << 0x08 | ubyte0
                j = j + 2

                -- print(strfmt("word: %04X", words[1 + j_2]))
                -- if j >= 10 then return nil end
            end

            local wordsPerRow = math.ceil(widthImage / 16)

            -- TODO: Can all this be flattened?
            local y = 0
            while y < heightImage do
                ---@type integer[]
                local pxRow = {}
                local yWord = y * planes

                local z = 0
                while z < planes do
                    local flatWord = (z + yWord) * wordsPerRow

                    local x = 0
                    while x < widthImage do
                        local xWord = x // 16
                        local word = words[1 + xWord + flatWord]

                        local xBit = x % 16
                        local shift = 15 - xBit
                        local bit = (word >> shift) & 1
                        local composite = pxRow[1 + x]
                        if composite then
                            pxRow[1 + x] = composite | (bit << z)
                        else
                            pxRow[1 + x] = bit << z
                        end

                        x = x + 1
                    end

                    z = z + 1
                end

                -- print(table.concat(pxRow, ", "))
                -- if y>=1 then return nil end

                local lenPxRow = #pxRow
                local k = 0
                while k < lenPxRow do
                    k = k + 1
                    pixels[#pixels + 1] = pxRow[k]
                end

                y = y + 1
            end

            blockLen = 8 + lenLocal
        else
            if #headerlc >= 4 then
                -- https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap#ILBM.DRNG
                -- https://amiga.lychesis.net/applications/Graphicraft.html
                print(strfmt("Unexpected found. Cursor: %d. Header:  %s",
                    cursor, headerlc))
                blockLen = block4
                return nil
            end
        end

        cursor = cursor + blockLen
    end

    local widthSprite = widthImage
    local heightSprite = heightImage
    local xaReduced, yaReduced = reduceRatio(xAspect, yAspect)
    local useBake = aspectResponse == "BAKE"
    if useBake then
        widthSprite = widthImage * xaReduced
        heightSprite = heightImage * yaReduced
    end

    local sRGBColorSpace = ColorSpace { sRGB = true }

    local imageSpec = ImageSpec {
        width = widthImage,
        height = heightImage,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    imageSpec.colorSpace = sRGBColorSpace

    local image = Image(imageSpec)
    local pxItr = image:pixels()
    for pixel in pxItr do
        pixel(pixels[1 + pixel.x + pixel.y * widthImage])
    end

    if useBake then
        image:resize(widthSprite, heightSprite)
    end

    local spriteSpec = ImageSpec {
        width = widthSprite,
        height = heightSprite,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    spriteSpec.colorSpace = sRGBColorSpace

    local sprite = Sprite(spriteSpec)
    if aspectResponse == "SPRITE_RATIO" then
        sprite.pixelRatio = Size(xaReduced, yaReduced)
    end

    app.command.BackgroundFromLayer()

    app.transaction(function()
        local palette = sprite.palettes[1]
        local lenAseColors = #aseColors
        palette:resize(lenAseColors)
        local i = 0
        while i < lenAseColors do
            i = i + 1
            local aseColor = aseColors[i]
            palette:setColor(i - 1, aseColor)
        end
    end)

    sprite.cels[1].image = image
    sprite.filename = app.fs.filePathAndTitle(importFilepath)

    return sprite
end

local dlg = Dialog { title = "IFF Import Export" }

dlg:combobox {
    id = "aspectResponse",
    label = "Aspect:",
    option = defaults.aspectResponse,
    options = aspectResponses,
    focus = false
}

dlg:newrow { always = false }

dlg:file {
    id = "importFilepath",
    label = "Open:",
    filetypes = fileTypes,
    open = true,
    focus = true
}

dlg:newrow { always = false }

dlg:button {
    id = "importButton",
    text = "&IMPORT",
    focus = false,
    onclick = function()
        -- Check for invalid file path.
        local args = dlg.data
        local importFilepath = args.importFilepath --[[@as string]]
        if (not importFilepath) or #importFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        -- Preserve fore- and background colors.
        local fgc = app.fgColor
        app.fgColor = Color {
            r = fgc.red,
            g = fgc.green,
            b = fgc.blue,
            a = fgc.alpha
        }

        app.command.SwitchColors()
        local bgc = app.fgColor
        app.fgColor = Color {
            r = bgc.red,
            g = bgc.green,
            b = bgc.blue,
            a = bgc.alpha
        }
        app.command.SwitchColors()

        local aspectResponse = args.aspectResponse
            or defaults.aspectResponse --[[@as string]]

        local sprite = readFile(importFilepath, aspectResponse)
        if sprite then
            app.command.FitScreen()
            app.refresh()
        end
    end
}

dlg:separator { id = "cancelSep" }

dlg:button {
    id = "cancel",
    text = "&CANCEL",
    focus = false,
    onclick = function()
        dlg:close()
    end
}

dlg:show { wait = false }
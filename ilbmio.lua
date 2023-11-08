local uiAvailable = app.isUIAvailable

local fileTypes = { "iff", "ilbm", "lbm" }
local aspectResponses = { "BAKE", "SPRITE_RATIO", "IGNORE" }

local defaults = {
    aspectResponse = "SPRITE_RATIO",
    maxAspect = 16,
    maxFrames = 512
}

---@param bytes integer[]
---@return integer[]
local function decompress(bytes)
    ---@type integer[]
    local decompressed = {}
    local lenBytes = #bytes
    local j = 0
    while j < lenBytes do
        local byte = bytes[1 + j]
        local readStep = 1

        -- The algorithm is adjusted for unsigned bytes, not signed.
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

    return decompressed
end

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
local function lcm(a, b)
    return (a // gcd(a, b)) * b
end

---@param a integer
---@param b integer
---@return integer
---@return integer
local function reduceRatio(a, b)
    local denom <const> = gcd(a, b)
    return a // denom, b // denom
end

---@param sprite Sprite
---@return string
local function writeFile(sprite)
    local strpack = string.pack
    local spriteSpec = sprite.spec
    local widthSprite = spriteSpec.width
    local heightSprite = spriteSpec.height
    local pxRatio = sprite.pixelRatio
    local xAspect = math.max(1, math.abs(pxRatio.w))
    local yAspect = math.max(1, math.abs(pxRatio.h))
    local planes = 8 -- 2 ^ 8 = 256
    local binStrs = {
        "FORM",
        strpack(">I4", 0), -- TODO: Replace later.
        "ILBM",
        "BMHD",
        strpack(">I4", 20),
        strpack(">I4", widthSprite << 0x10 | heightSprite),
        strpack(">I4", 0 << 0x10 | 0), --xOrig, yOrig
    }

    local binStr = table.concat(binStrs, "")
    local lenBinStr = #binStr
    local formLen = lenBinStr - 4
    return binStr
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

    local binData = binFile:read("a")
    binFile:close()

    local strfmt = string.format
    local strlower = string.lower
    local strsub = string.sub
    local strunpack = string.unpack
    local strbyte = string.byte

    local lenBinData = #binData
    local chunkLen = 4

    local colorMode = ColorMode.INDEXED
    local wImage = 1
    local hImage = 1
    local planes = 0
    -- TODO: Handle these enum cases better.
    -- mskNone an opaque image
    -- mskHasMask
    -- mskHasTransparentColor
    -- mskLasso
    local masking = 0
    local compressed = 0
    local alphaIndex = 0
    local xAspect = 1
    local yAspect = 1
    local wSprite = 1
    local hSprite = 1

    local isPbm = false
    local extraHalfBrite = false

    ---@type {orig: integer, dest: integer, span: integer, isReverse: boolean}[]
    local colorCycles = {}

    ---@type Color[]
    local aseColors = {}

    ---@type integer[]
    local pixels = {}

    local cursor = 1
    while cursor <= lenBinData do
        local header = strsub(binData, cursor, cursor + 3)
        local headerlc = strlower(header)
        if headerlc == "form" then
            print(strfmt("\nFORM found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenInt = strunpack(">I4", lenStr)
            print(strfmt("lenInt: %d", lenInt))
            chunkLen = 8
        elseif headerlc == "ilbm" then
            print(strfmt("\nILBM found. Cursor: %d.", cursor))
            chunkLen = 4
        elseif headerlc == "pbm " then
            print(strfmt("\nPBM found. Cursor: %d.", cursor))
            isPbm = true
            chunkLen = 4
        elseif headerlc == "bmhd" then
            print(strfmt("\nBMHD found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            local wStr = strsub(binData, cursor + 8, cursor + 9)
            local hStr = strsub(binData, cursor + 10, cursor + 11)
            wImage = strunpack(">I2", wStr)
            hImage = strunpack(">I2", hStr)
            print(strfmt("width: %d", wImage))
            print(strfmt("height: %d", hImage))

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
            wSprite = strunpack(">I2", pgwStr)
            hSprite = strunpack(">I2", pghStr)
            print(strfmt("pageWidth: %d", wSprite))
            print(strfmt("pageHeight: %d", hSprite))

            chunkLen = 8 + lenLocal
        elseif headerlc == "cmap" then
            print(strfmt("\nCMAP found. Cursor: %d.", cursor))
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
                print(strfmt("%03d: %03d %03d %03d, #%06x",
                    i, r8, g8, b8, r8 << 0x10 | g8 << 0x08 | b8))
                local aseColor = Color { r = r8, g = g8, b = b8, a = 255 }

                i = i + 1
                aseColors[i] = aseColor
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "camg" then
            -- TODO: This needs to parse correcly for HAM.

            -- Hires must impact aspect ratio, e.g., 20x11 should be 10x11?
            print(strfmt("\nCAMG found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            local flagsStr = strsub(binData, cursor + 8, cursor + 11)
            local flags = strunpack(">I4", flagsStr)
            print(strfmt("flags: %d 0x%04x", flags, flags))

            extraHalfBrite = (flags & 0x80) ~= 0
            if extraHalfBrite then
                print("Extra Half Brite.")

                local i = 0
                while i < 32 do
                    i = i + 1
                    local aseColor = aseColors[i]
                    local ehbColor = Color {
                        r = aseColor.red >> 1,
                        g = aseColor.green >> 1,
                        b = aseColor.blue >> 1,
                        a = 255
                    }
                    aseColors[32 + i] = ehbColor
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "ccrt" then
            print(strfmt("\nCCRT found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            local dirStr = strsub(binData, cursor + 8, cursor + 9)
            local dir = strunpack(">i2", dirStr)
            print(strfmt("dir: %d", dir))

            if dir ~= 0 then
                local origStr = strsub(binData, cursor + 10, cursor + 10)
                local destStr = strsub(binData, cursor + 11, cursor + 11)

                local orig = strunpack(">I1", origStr)
                local dest = strunpack(">I1", destStr)

                print(strfmt("orig: %d", orig))
                print(strfmt("dest: %d", dest))

                local span = 1 + dest - orig
                if span > 1 then
                    colorCycles[#colorCycles + 1] = {
                        orig = orig,
                        dest = dest,
                        span = span,
                        isReverse = dir < 0
                    }
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "crng" then
            print(strfmt("\nCRNG found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            local flagsStr = strsub(binData, cursor + 12, cursor + 13)
            local flags = strunpack(">I2", flagsStr)
            print(strfmt("flags: %d 0x%04x", flags, flags))
            if ((flags >> 1) & 1) ~= 0 then
                print("isReversed")
            end

            -- In many test files, these CRNG tags contain crud data, such as
            -- zero flags, orig and dest being equal, or rate being zero.
            if (flags & 1) ~= 0 then
                local origStr = strsub(binData, cursor + 14, cursor + 14)
                local destStr = strsub(binData, cursor + 15, cursor + 15)

                local orig = strunpack(">I1", origStr)
                local dest = strunpack(">I1", destStr)

                print(strfmt("orig: %d", orig))
                print(strfmt("dest: %d", dest))

                local span = 1 + dest - orig
                if span > 1 then
                    local rateStr = strsub(binData, cursor + 10, cursor + 11)
                    local rate = strunpack(">I2", rateStr)
                    if rate > 0 then
                        print(strfmt("rate: %d", rate))

                        colorCycles[#colorCycles + 1] = {
                            orig = orig,
                            dest = dest,
                            span = span,
                            isReverse = ((flags >> 1) & 1) ~= 0
                        }
                    end
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "body" then
            print(strfmt("\nBODY found. Cursor: %d.", cursor))
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
                bytes = decompress(bytes)
            end

            if isPbm then
                pixels = bytes
            else
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

                local wordsPerRow = math.ceil(wImage / 16)

                -- TODO: Can all this be flattened?
                local y = 0
                while y < hImage do
                    ---@type integer[]
                    local pxRow = {}
                    local yWord = y * planes

                    local z = 0
                    while z < planes do
                        local flatWord = (z + yWord) * wordsPerRow

                        local x = 0
                        while x < wImage do
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
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "auth" then
            -- Author information.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            chunkLen = 8 + lenLocal
        elseif headerlc == "dpps" then
            -- Don't know what this is, but it's found in the King Tut image.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            chunkLen = 8 + lenLocal
        elseif headerlc == "dppv" then
            -- Perspective and transformation.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            chunkLen = 8 + lenLocal
        elseif headerlc == "tiny" then
            -- Thumbnail.
            print(strfmt("TINY found. Cursor: %d", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("lenLocal: %d", lenLocal))

            -- 9 instead of 8 is a fudge.
            chunkLen = 9 + lenLocal
        else
            if cursor <= lenBinData and #headerlc >= 4 then
                -- https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap#ILBM.DRNG
                -- https://amiga.lychesis.net/applications/Graphicraft.html
                -- print(strfmt("Unexpected found. Cursor: %d. Header:  %s",
                --     cursor, headerlc))
                chunkLen = 4
            end
        end

        cursor = cursor + chunkLen
    end

    local xaReduced, yaReduced = reduceRatio(xAspect, yAspect)
    xaReduced = math.min(math.max(xaReduced, 1), defaults.maxAspect)
    yaReduced = math.min(math.max(yaReduced, 1), defaults.maxAspect)

    local sRGBColorSpace = ColorSpace { sRGB = true }

    local imageSpec = ImageSpec {
        width = wImage,
        height = hImage,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    imageSpec.colorSpace = sRGBColorSpace

    local stillImage = Image(imageSpec)
    local pxItr = stillImage:pixels()
    for pixel in pxItr do
        pixel(pixels[1 + pixel.x + pixel.y * wImage])
    end

    local spriteSpec = ImageSpec {
        width = wSprite,
        height = hSprite,
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

    sprite.cels[1].image = stillImage
    sprite.filename = app.fs.filePathAndTitle(importFilepath)

    local lenColorCycles = #colorCycles
    print(strfmt("lenColorCycles: %d", lenColorCycles))
    if lenColorCycles > 0 then
        local activeLayer = sprite.layers[1]

        -- Create a dictionary where a palette index, the key, is assigned an
        -- array of all the flattened coordinates (i=x + y * w) where the index
        -- is used.
        ---@type table<integer, integer[]>
        local histogram = {}
        local lenPixels = #pixels
        local e = 0
        while e < lenPixels do
            local palIdx = pixels[1 + e]
            local arr = histogram[palIdx]
            if arr then
                arr[#arr + 1] = e
            else
                histogram[palIdx] = { e }
            end
            e = e + 1
        end

        -- Find least common multiple so that color cycles can repeat.
        local requiredFrames = 1
        local f = 0
        while f < lenColorCycles do
            f = f + 1
            local colorCycle = colorCycles[f]
            local span = colorCycle.span

            requiredFrames = lcm(requiredFrames, span)
        end
        print(strfmt("\nLeast common multiple: %d", requiredFrames))

        if requiredFrames <= defaults.maxFrames then
            -- Copy still image to new frames.
            app.transaction(function()
                local g = 1
                while g < requiredFrames do
                    g = g + 1
                    local frObj = sprite:newEmptyFrame()
                    sprite:newCel(activeLayer, frObj, stillImage)
                end
            end)

            local h = 0
            while h < lenColorCycles do
                h = h + 1
                local colorCycle = colorCycles[h]
                local palIdxOrig = colorCycle.orig
                local palSpan = colorCycle.span
                local isReverse = colorCycle.isReverse
                local palIncr = -1
                if isReverse then palIncr = 1 end

                local frIdx = 1
                while frIdx < requiredFrames do
                    frIdx = frIdx + 1

                    local shift = (frIdx - 1) * palIncr
                    local cel = activeLayer:cel(frIdx)
                    if cel then
                        local frImage = cel.image

                        local j = 0
                        while j < palSpan do
                            local currIdx = palIdxOrig + j
                            if currIdx ~= alphaIndex then
                                local usedPixels = histogram[currIdx]
                                if usedPixels then
                                    local shifted = palIdxOrig + (j + shift) % palSpan
                                    local lenUsedPixels = #usedPixels
                                    local k = 0
                                    while k < lenUsedPixels do
                                        k = k + 1
                                        local coord = usedPixels[k]
                                        local x = coord % wImage
                                        local y = coord // wImage
                                        frImage:drawPixel(x, y, shifted)
                                    end -- End of pixels used by hex loop.
                                end -- End of histogram array exists at key.
                            end -- End current index not alpha.

                            j = j + 1
                        end -- End of palette span loop.
                    end     -- End of cel exists check.
                end         -- End of frame loop.
            end             -- End of color cycles loop.
        end                 -- End beneath frame max.
    end                     -- End of add color cycle data check.

    if aspectResponse == "BAKE" then
        sprite:resize(wSprite * xaReduced, hSprite * yaReduced)
    end

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
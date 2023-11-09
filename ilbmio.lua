local uiAvailable = app.isUIAvailable

local importFileTypes = { "iff", "ilbm", "lbm" }
local exportFileTypes = { "ilbm", "lbm" }
local aspectResponses = { "BAKE", "SPRITE_RATIO", "IGNORE" }

local defaults = {
    -- To test anim files: https://aminet.net/pix/anim
    -- https://www.wikiwand.com/en/LHA_(file_format)
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

---@param x integer
---@return integer
local function nextPowerOf2(x)
    if x ~= 0 then
        local xSgn = 1
        local xAbs = x
        if x < 0 then
            xAbs = -x
            xSgn = -1
        end
        local p = 1
        while p < xAbs do
            p = p << 1
        end
        return p * xSgn
    end
    return 0
end

---@param sprite Sprite
---@param frObj Frame
---@param isPbm boolean
---@return string
local function writeFile(sprite, frObj, isPbm)
    -- Cache methods.
    local strpack = string.pack
    local strchar = string.char
    local abs = math.abs
    local ceil = math.ceil
    local log = math.log
    local max = math.max
    local min = math.min

    -- Unpack sprite.
    local spriteSpec = sprite.spec
    local palettes = sprite.palettes
    local pxRatio = sprite.pixelRatio

    -- Unpack sprite spec.
    -- Sprites need to be 320x200 or so in order to load...
    local wSprite = spriteSpec.width
    local hSprite = spriteSpec.height
    local alphaIndex = spriteSpec.transparentColor
    local colorMode = spriteSpec.colorMode

    -- Unpack sprite pixel aspect.
    local xAspect = max(1, abs(pxRatio.w))
    local yAspect = max(1, abs(pxRatio.h))

    local palette = nil
    local planes = 8
    local writeCmap = true
    local writeTrueColor24 = false
    local writeTrueColor32 = false
    local lenPaletteActual = 0

    if colorMode == ColorMode.RGB then
        -- TODO: How to handle this case? Maybe make a dummy sprite copy, then
        -- convert to index, then close when this process is done?
        palette = sprite.palettes[1]
        if sprite.backgroundLayer then
            planes = 24
            writeTrueColor24 = true
        else
            planes = 32
            writeTrueColor32 = true
        end
        writeCmap = false
    elseif colorMode == ColorMode.GRAY then
        palette = Palette(256)
        local i = 0
        while i < 256 do
            palette:setColor(i, Color { r = i, g = i, b = i, a = 255 })
            i = i + 1
        end
        planes = 8
        lenPaletteActual = 256
    else
        -- Assume indexed color is the default.
        -- 2 ^ 1 =   2
        -- 2 ^ 2 =   4
        -- 2 ^ 3 =   8
        -- 2 ^ 4 =  16
        -- 2 ^ 5 =  32
        -- 2 ^ 6 =  64
        -- 2 ^ 7 = 128
        -- 2 ^ 8 = 256
        local palIdx = 1
        local frIdx = frObj.frameNumber
        local lenPalettes = #palettes
        if frIdx <= lenPalettes then palIdx = frIdx end
        palette = palettes[palIdx]
        lenPaletteActual = #palette
        planes = max(1, ceil(log(min(256, lenPaletteActual), 2)))
    end

    local formatHeader = "ILBM"
    if isPbm then formatHeader = "PBM " end

    local lenBodyData = 0
    if isPbm then
        lenBodyData = wSprite * hSprite
    else
        local wordsPerRow = ceil(wSprite / 16)
        local charsPerRow = wordsPerRow * 2
        lenBodyData = hSprite * planes * charsPerRow
    end

    local lenCmapData = 0
    if writeCmap then
        lenCmapData = 3 * nextPowerOf2(min(256, lenPaletteActual))
    end

    local formLength = 0 -- Form header
        + 4              -- ILBM/PBM header
        + 8              -- BMHD header
        + 20             -- BMHD content
    if writeCmap then
        formLength = formLength + 8 + lenCmapData
    end
    formLength = formLength + 8 + lenBodyData

    ---@type string[]
    local binWords = {
        "FORM",
        strpack(">I4", formLength),
        formatHeader,
        "BMHD",
        strpack(">I4", 20),                                           -- Chunk length. (5 words * 4)
        strpack(">I2", wSprite),                                      -- 1. width
        strpack(">I2", hSprite),                                      -- 1. height
        strpack(">I2", 0),                                            -- 2. xOrig
        strpack(">I2", 0),                                            -- 2. yOrig
        strpack(">I4", planes << 0x18),                               -- 3. planes, mask, compression
        strpack(">I4", alphaIndex << 10 | xAspect << 0x08 | yAspect), -- 4. alpha mask, px aspect ratio
        strpack(">I2", wSprite),                                      -- 5. page width
        strpack(">I2", hSprite),                                      -- 5. page height
    }

    if writeCmap then
        binWords[#binWords + 1] = "CMAP"
        binWords[#binWords + 1] = strpack(">I4", lenCmapData)

        local i = 0
        local lenPaletteClamped = min(256, lenPaletteActual)
        while i < lenPaletteClamped do
            local aseColor = palette:getColor(i)
            local rChar = strchar(aseColor.red)
            local gChar = strchar(aseColor.green)
            local bChar = strchar(aseColor.blue)
            binWords[#binWords + 1] = rChar
            binWords[#binWords + 1] = gChar
            binWords[#binWords + 1] = bChar
            i = i + 1
        end

        local expectedPalette = lenCmapData // 3
        while i < expectedPalette do
            binWords[#binWords + 1] = strchar(0)
            binWords[#binWords + 1] = strchar(0)
            binWords[#binWords + 1] = strchar(0)
            i = i + 1
        end
    end

    binWords[#binWords + 1] = "BODY"
    binWords[#binWords + 1] = strpack(">I4", lenBodyData)

    local flat = Image(spriteSpec)
    flat:drawSprite(sprite, 1)
    local pxItr = flat:pixels()
    if isPbm then
        for pixel in pxItr do
            local idx = pixel()
            binWords[#binWords + 1] = strchar(idx)
        end
    else
        -- TODO: IMPLEMENT
    end

    local binStr = table.concat(binWords, "")
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

    local bodyFound = false
    local lenBinData = #binData
    local chunkLen = 4

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
    local isExtraHalf = false
    local isHighRes = false
    local isInterlaced = false
    local isHam = false
    local isTrueColor24 = false
    local isTrueColor32 = false

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
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenInt = strunpack(">I4", lenStr)
            print(strfmt("\nFORM found. Cursor: %d.\nlenInt: %d",
                cursor, lenInt))
            chunkLen = 8
        elseif headerlc == "ilbm" then
            print(strfmt("\nILBM found. Cursor: %d.", cursor))
            chunkLen = 4
        elseif headerlc == "pbm " then
            print(strfmt("\nPBM found. Cursor: %d.", cursor))
            isPbm = true
            chunkLen = 4
            -- elseif headerlc == "anim" then
            --     print(strfmt("\nANIM found. Cursor: %d.", cursor))
            --     isPbm = true
            --     chunkLen = 4
        elseif headerlc == "bmhd" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nBMHD found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

            -- Word 1.
            local wStr = strsub(binData, cursor + 8, cursor + 9)
            local hStr = strsub(binData, cursor + 10, cursor + 11)
            wImage = strunpack(">I2", wStr)
            hImage = strunpack(">I2", hStr)
            wSprite = wImage
            hSprite = hImage
            print(strfmt("width: %d\nheight: %d", wImage, hImage))

            -- Word 2.
            local planesStr = strsub(binData, cursor + 16, cursor + 16)
            local maskStr = strsub(binData, cursor + 17, cursor + 17)
            local comprStr = strsub(binData, cursor + 18, cursor + 18)

            -- Word 3.
            planes = strunpack(">I1", planesStr)
            masking = strunpack(">I1", maskStr)
            compressed = strunpack(">I1", comprStr)
            isTrueColor24 = planes == 24
            isTrueColor32 = planes == 32
            print(strfmt(
                "planes: %d\nmasking: %d\ncompressed: %d",
                planes, masking, compressed))

            if isTrueColor24 or isTrueColor32 then
                print("True color image.")
            end

            -- Word 4.
            local trclStr = strsub(binData, cursor + 20, cursor + 21)
            local xAspStr = strsub(binData, cursor + 22, cursor + 22)
            local yAspStr = strsub(binData, cursor + 23, cursor + 23)
            alphaIndex = strunpack(">I2", trclStr)
            xAspect = strunpack(">I1", xAspStr)
            yAspect = strunpack(">I1", yAspStr)
            print(strfmt("alphaIndex: %d", alphaIndex))
            print(strfmt("xAspect: %d", xAspect))
            print(strfmt("yAspect: %d", yAspect))

            -- Word 5.
            local pgwStr = strsub(binData, cursor + 24, cursor + 25)
            local pghStr = strsub(binData, cursor + 26, cursor + 27)
            wSprite = strunpack(">I2", pgwStr)
            hSprite = strunpack(">I2", pghStr)
            print(strfmt("wSprite: %d\nhSprite: %d", wSprite, hSprite))

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
                local aseColor = Color { r = r8, g = g8, b = b8, a = 255 }
                i = i + 1
                aseColors[i] = aseColor

                print(strfmt("%03d: %03d %03d %03d, #%06x",
                    i - 1, r8, g8, b8, r8 << 0x10 | g8 << 0x08 | b8))
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "camg" then
            -- Hires must impact aspect ratio, e.g., 20x11 should be 10x11?
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nCAMG found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

            local flagsStr = strsub(binData, cursor + 8, cursor + 11)
            local flags = strunpack(">I4", flagsStr)
            print(strfmt("flags: %d 0x%04x", flags, flags))

            isHighRes = (flags & 0x8000) ~= 0
            isHam = (flags & 0x800) ~= 0
            isExtraHalf = (flags & 0x80) ~= 0
            isInterlaced = (flags & 0x4) ~= 0

            if isHighRes then print("High res.") end
            if isHam then print("HAM.") end
            if isExtraHalf then print("Extra Half Bright") end
            if isInterlaced then print("Interlaced.") end

            chunkLen = 8 + lenLocal
        elseif headerlc == "drng" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nDRNG found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

            -- https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap#ILBM.DRNG
            -- TODO: This allows the possibility of non-contiguous indices, so
            -- you'll have to redo your colorCycle palettes format.

            chunkLen = 8 + lenLocal
        elseif headerlc == "ccrt" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nCCRT found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

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
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nCRNG found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

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
                    print(strfmt("rate: %d", rate))

                    if rate > 0 then
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
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nBODY found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

            bodyFound = true

            -- CAMG chunk may be missing entirely, or occur before CMAP chunk,
            -- so this needs to wait until body to figure out...
            if wImage >= 640 then isHighRes = true end
            if hImage >= 400 then isInterlaced = true end

            if isExtraHalf then
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
                print(strfmt("Decompressed: %d", #bytes))
            end

            -- TODO: Support true color.
            if isPbm then
                pixels = bytes
            else
                ---@type integer[]
                local words = {}
                local lenBytes = #bytes
                local j = 0
                while j < lenBytes do
                    local j_2 = j // 2
                    -- For unsigned byte.
                    -- If signed byte, mask by byte & 0xff.
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

                    -- TODO: Is there a way that this step can be skipped?
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
            -- Author.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("AUTH found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "anno" then
            -- Annotation.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("ANNO found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dpi " then
            -- Divets per inch.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("DPI found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dpps" then
            -- Don't know what this is, but it's found in the King Tut image.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("DPPS found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dppv" then
            -- Perspective and transformation.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("DDPV found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "tiny" then
            -- Thumbnail.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("TINY found. Cursor: %d\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal

            -- Some Mark Ferrari files have extra zeroes at the end of tiny
            -- chunks which make it hard to find body.
            while strbyte(binData, cursor + chunkLen) == 0 do
                chunkLen = chunkLen + 1
            end
        else
            if cursor <= lenBinData and #headerlc >= 4 then
                chunkLen = 4

                print(strfmt("Unexpected found. Cursor: %d. Header:  %s",
                    cursor, headerlc))
                return nil
            end
        end

        cursor = cursor + chunkLen
    end

    local xaReduced, yaReduced = reduceRatio(xAspect, yAspect)
    xaReduced = math.min(math.max(xaReduced, 1), defaults.maxAspect)
    yaReduced = math.min(math.max(yaReduced, 1), defaults.maxAspect)

    local sRGBColorSpace = ColorSpace { sRGB = true }
    local colorMode = ColorMode.INDEXED
    if isTrueColor24 or isTrueColor32 then
        colorMode = ColorMode.RGB
    end

    local imageSpec = ImageSpec {
        width = wImage,
        height = hImage,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    imageSpec.colorSpace = sRGBColorSpace

    local spriteSpec = ImageSpec {
        width = wSprite,
        height = hSprite,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    spriteSpec.colorSpace = sRGBColorSpace

    local sprite = Sprite(spriteSpec)
    sprite.filename = app.fs.filePathAndTitle(importFilepath)
    if aspectResponse == "SPRITE_RATIO" then
        sprite.pixelRatio = Size(xaReduced, yaReduced)
    end

    local lenAseColors = #aseColors
    if lenAseColors > 0 then
        app.transaction(function()
            local palette = sprite.palettes[1]
            palette:resize(lenAseColors)
            local i = 0
            while i < lenAseColors do
                i = i + 1
                local aseColor = aseColors[i]
                palette:setColor(i - 1, aseColor)
            end
        end)
    end

    if not bodyFound then
        if aspectResponse == "BAKE" then
            sprite:resize(wSprite * xaReduced, hSprite * yaReduced)
        end
        return sprite
    end

    local stillImage = Image(imageSpec)
    local pxItr = stillImage:pixels()
    for pixel in pxItr do
        pixel(pixels[1 + pixel.x + pixel.y * wImage])
    end
    if not isTrueColor32 then
        app.command.BackgroundFromLayer()
    end
    sprite.cels[1].image = stillImage

    if #aseColors <= 0 then
        app.command.ColorQuantization {
            ui = false,
            maxColors = 256,
            withAlpha = false
        }
    end

    local lenColorCycles = #colorCycles
    print(strfmt("\nlenColorCycles: %d", lenColorCycles))
    if lenColorCycles > 0 then
        -- TODO: Do color cycling indices work differently for extra half brite?

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
        print(strfmt("Least common multiple: %d", requiredFrames))

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
                                end     -- End of histogram array exists at key.
                            end         -- End current index not alpha.

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
    filetypes = importFileTypes,
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

dlg:separator { id = "exportSep" }

dlg:file {
    id = "exportFilepath",
    label = "Save:",
    filetypes = exportFileTypes,
    save = true,
    focus = false
}

dlg:newrow { always = false }

dlg:button {
    id = "export",
    text = "&EXPORT",
    focus = false,
    onclick = function()
        ---@diagnostic disable-next-line: deprecated
        local activeSprite = app.activeSprite
        if not activeSprite then
            app.alert {
                title = "Error",
                text = "There is no active sprite."
            }
            return
        end

        ---@diagnostic disable-next-line: deprecated
        local activeFrame = app.activeFrame
        if not activeFrame then
            app.alert {
                title = "Error",
                text = "There is no active frame."
            }
            return
        end

        -- Check for invalid file path.
        local args = dlg.data
        local exportFilepath = args.exportFilepath --[[@as string]]
        if (not exportFilepath) or #exportFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        local binFile, err = io.open(exportFilepath, "wb")
        if err ~= nil then
            if binFile then binFile:close() end
            app.alert { title = "Error", text = err }
            return
        end
        if binFile == nil then return end

        local fileExt = string.lower(app.fs.fileExtension(exportFilepath))
        local isPbm = fileExt == "lbm"
        local binStr = writeFile(activeSprite, activeFrame, isPbm)
        binFile:write(binStr)
        binFile:close()

        app.alert {
            title = "Success",
            text = "File exported."
        }
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
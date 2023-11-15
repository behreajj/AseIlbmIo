local uiAvailable = app.isUIAvailable

local importFileTypes = { "iff", "ilbm", "lbm" }
local exportFileTypes = { "ilbm", "lbm" }
local aspectResponses = { "BAKE", "SPRITE_RATIO", "IGNORE" }

local defaults = {
    -- To test anim files: https://aminet.net/pix/anim
    aspectResponse = "SPRITE_RATIO",
    maxAspect = 16,
    maxFrames = 512,
    useCompress = false,
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

---@param bytes integer[]
---@return integer[]
local function decompress(bytes)
    ---@type integer[]
    local decompressed = {}
    local lenBytes = #bytes
    local j = 0
    while j < lenBytes do
        local byte = bytes[1 + j]
        print(string.format("byte: %d", byte))
        local readStep = 1

        -- The algorithm is adjusted for unsigned bytes, not signed.
        if byte > 128 then
            local next = bytes[2 + j]
            print(string.format("repeating: %d", next))
            readStep = 2
            local k = 0
            print(string.format("257-byte: %d", (257 - byte)))
            while k < (257 - byte) do
                decompressed[#decompressed + 1] = next
                k = k + 1
            end
        elseif byte < 128 then
            print("unique")
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

---@param sprite Sprite
---@param frObj Frame
---@param isPbm boolean
---@param useCompress boolean
---@return string
local function writeFile(sprite, frObj, isPbm, useCompress)
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
    local wSprite = spriteSpec.width
    local hSprite = spriteSpec.height
    local alphaIndex = spriteSpec.transparentColor
    local colorMode = spriteSpec.colorMode

    -- Unpack sprite pixel aspect.
    local xAspect = max(1, abs(pxRatio.w))
    local yAspect = max(1, abs(pxRatio.h))

    -- No. of Planes = log(lenPalette, 2)
    -- 2 ^ 1 =   2, 2 ^ 5 =  32
    -- 2 ^ 2 =   4, 2 ^ 6 =  64
    -- 2 ^ 3 =   8, 2 ^ 7 = 128
    -- 2 ^ 4 =  16, 2 ^ 8 = 256
    local planes = 8

    ---@type integer[]
    local pixels = {}
    local palette = nil
    local lenPaletteActual = 0

    local flatSpec = ImageSpec {
        width = wSprite,
        height = hSprite,
        colorMode = colorMode,
        transparentColor = alphaIndex
    }
    flatSpec.colorSpace = spriteSpec.colorSpace
    local flat = Image(flatSpec)

    local isTrueColor24 = false
    -- local isTrueColor32 = false
    local writeCmap = true

    if spriteSpec.colorMode == ColorMode.INDEXED then
        local palIdx = 1
        local frIdx = frObj.frameNumber
        local lenPalettes = #palettes
        if frIdx <= lenPalettes then palIdx = frIdx end
        palette = palettes[palIdx]
        lenPaletteActual = #palette

        flat:drawSprite(sprite, frObj)
        local pxItr = flat:pixels()
        for pixel in pxItr do
            pixels[#pixels + 1] = pixel()
        end

        if not isPbm then
            planes = max(1, ceil(log(min(256, lenPaletteActual), 2)))
        end
    elseif colorMode == ColorMode.GRAY then
        -- TODO: Support alpha for true color 32?
        lenPaletteActual = 256
        palette = Palette(256)
        local i = 0
        while i < 256 do
            palette:setColor(i, Color { r = i, g = i, b = i, a = 255 })
            i = i + 1
        end

        flat:drawSprite(sprite, frObj)
        local pxItr = flat:pixels()
        for pixel in pxItr do
            local av16 = pixel()
            local a8 = (av16 >> 0x08) & 0xff
            if a8 <= 0 then
                pixels[#pixels + 1] = alphaIndex
            else
                local v8 = av16 & 0xff
                pixels[#pixels + 1] = v8
            end
        end
    else
        -- Default to RGB color mode.

        local palIdx = 1
        local frIdx = frObj.frameNumber
        local lenPalettes = #palettes
        if frIdx <= lenPalettes then palIdx = frIdx end
        palette = palettes[palIdx]
        lenPaletteActual = #palette

        if isPbm then
            flat:drawSprite(sprite, frObj)
            local pxItr = flat:pixels()
            for pixel in pxItr do
                local abgr32 = pixel()
                local a8 = (abgr32 >> 0x18) & 0xff
                if a8 <= 0 then
                    pixels[#pixels + 1] = alphaIndex
                else
                    local r8 = abgr32 & 0xff
                    local g8 = (abgr32 >> 0x08) & 0xff
                    local b8 = (abgr32 >> 0x10) & 0xff
                    local aseColor = Color { r = r8, g = g8, b = b8, a = 255 }
                    pixels[#pixels + 1] = aseColor.index
                end
            end
        else
            writeCmap = false
            if sprite.backgroundLayer ~= nil then
                isTrueColor24 = true
                planes = 24
            else
                planes = 32
            end

            local mask = isTrueColor24 and 0x00ffffff or 0xffffffff

            flat:drawSprite(sprite, frObj)
            local pxItr = flat:pixels()
            for pixel in pxItr do
                pixels[#pixels + 1] = mask & pixel()
            end
        end
    end

    -- Do sprites need to be some proportion in order to load in Irfanview?
    local formatHeader = isPbm and "PBM " or "ILBM"
    local compressNum = useCompress and 1 or 0
    local wordsPerRow = ceil(wSprite / 16)
    local charsPerRow = wordsPerRow * 2
    local lenBodyData = isPbm
        and wSprite * hSprite
        or hSprite * planes * charsPerRow
    local lenCmapData = writeCmap
        and 3 * nextPowerOf2(min(256, lenPaletteActual))
        or 0
    local formLength = 0 -- Form header is excluded.
        + 4              -- ILBM / PBM header (no length).
        + 8              -- BMHD header
        + 20             -- BMHD content
        + 8              -- Body header
        + lenBodyData    -- Body content
    if writeCmap then
        formLength = formLength + 8 + lenCmapData
    end

    ---@type string[]
    local binData = {
        "FORM",
        strpack(">I4", formLength),
        formatHeader,
        "BMHD",
        strpack(">I4", 20),                           -- Chunk length.
        strpack(">I2", wSprite),                      -- 1. width
        strpack(">I2", hSprite),                      -- 1. height
        strpack(">I2", 0),                            -- 2. xOrig
        strpack(">I2", 0),                            -- 2. yOrig
        strpack(">I1", planes),                       -- 3. planes
        strpack(">I2", compressNum),                  -- 3. masking, compress
        strpack(">I1", 0),                            -- 3. reserved
        strpack(">I2", alphaIndex),                   -- 4. alpha mask
        strpack(">I1", xAspect),                      -- 4. aspect ratio x
        strpack(">I1", yAspect),                      -- 4. aspect ratio y
        strpack(">I2", wSprite),                      -- 5. page width
        strpack(">I2", hSprite),                      -- 5. page height
    }

    if writeCmap then
        binData[#binData + 1] = "CMAP"
        binData[#binData + 1] = strpack(">I4", lenCmapData)

        local i = 0
        local lenPaletteClamped = min(256, lenPaletteActual)
        while i < lenPaletteClamped do
            local aseColor = palette:getColor(i)
            local rChar = strchar(aseColor.red)
            local gChar = strchar(aseColor.green)
            local bChar = strchar(aseColor.blue)
            binData[#binData + 1] = rChar
            binData[#binData + 1] = gChar
            binData[#binData + 1] = bChar
            i = i + 1
        end

        local charZero = strchar(0)
        local expectedPalette = lenCmapData // 3
        while i < expectedPalette do
            binData[#binData + 1] = charZero
            binData[#binData + 1] = charZero
            binData[#binData + 1] = charZero
            i = i + 1
        end
    end

    binData[#binData + 1] = "BODY"
    binData[#binData + 1] = strpack(">I4", lenBodyData)

    if isPbm then
        local j = 0
        local lenPixels = #pixels
        while j < lenPixels do
            j = j + 1
            binData[#binData + 1] = strchar(pixels[j])
        end
    else
        local bytesPerRow = ceil(wSprite / 16) * 2
        local bprPlanes = planes * bytesPerRow
        local widthPlanes = wSprite * planes

        local y = 0
        while y < hSprite do
            ---@type integer[]
            local row = {}
            local h = 0
            while h < bprPlanes do
                h = h + 1
                row[h] = 0
            end

            local ywSprite = y * wSprite
            local i = 0
            while i < widthPlanes do
                local x = i // planes
                local z = i % planes
                local pixel = pixels[1 + x + ywSprite]
                if pixel & (1 << z) ~= 0 then
                    local xFlr = x // 8
                    local xRem = x % 8
                    local idxFlat = 1 + xFlr + z * bytesPerRow
                    row[idxFlat] = row[idxFlat]| 0x80 >> xRem
                end
                i = i + 1
            end

            if useCompress then
                ---@type integer[]
                local compressed = {}
                local j = 0
                local step = 1
                while j < #row do
                    local curr = row[1 + j]
                    local next = row[2 + j]

                    if next then
                        local instances = 0
                        repeat
                            instances = instances + 1
                            next = row[2 + j + instances]
                        until curr ~= next

                        if instances > 1 then
                            compressed[#compressed + 1] = -instances & 0xff
                            compressed[#compressed + 1] = curr
                            step = instances + 1
                        else
                            compressed[#compressed + 1] = curr
                            step = 1
                        end
                    else
                        compressed[#compressed + 1] = curr
                        step = 1
                    end

                    j = j + step
                end

                row = compressed
            end

            local k = 0
            local lenRow = #row
            while k < lenRow do
                k = k + 1
                binData[#binData + 1] = strchar(row[k])
            end

            y = y + 1
        end
    end

    local binStr = table.concat(binData, "")
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

    local lenForm = 0
    local wImage = 1
    local hImage = 1
    local planes = 0
    local masking = 0
    local compressed = 0
    local alphaIndex = 0
    local xAspect = 1
    local yAspect = 1
    local wSprite = 1
    local hSprite = 1

    local isPbm = false
    local isAcbm = false
    local isAnim = false
    local isExtraHalf = false
    local isHighRes = false
    local isInterlaced = false
    local isHam = false
    local isTrueColor24 = false
    local isTrueColor32 = false

    local sumDuration = 0.0
    local maxFrames = 1
    local currFrame = 0

    ---@type {orig: integer, dest: integer, span: integer, duration: number, isReverse: boolean}[]
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
            lenForm = strunpack(">I4", lenStr)
            -- print(strfmt("\nFORM found. Cursor: %d.\nlenForm: %d",
            --     cursor, lenForm))
            chunkLen = 8
        elseif headerlc == "ilbm" then
            -- print(strfmt("\nILBM found. Cursor: %d.", cursor))
            chunkLen = 4
        elseif headerlc == "pbm " then
            -- print(strfmt("\nPBM found. Cursor: %d.", cursor))
            isPbm = true
            chunkLen = 4
        elseif headerlc == "acbm" then
            print(strfmt("\nACBM found. Cursor: %d.", cursor))
            isAcbm = true
            chunkLen = 4
        elseif headerlc == "anim" then
            isAnim = true
            -- print(strfmt("\nANIM found. Cursor: %d.", cursor))
            chunkLen = 4
        elseif headerlc == "bmhd" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nBMHD found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            -- Word 1.
            local wStr = strsub(binData, cursor + 8, cursor + 9)
            local hStr = strsub(binData, cursor + 10, cursor + 11)
            wImage = strunpack(">I2", wStr)
            hImage = strunpack(">I2", hStr)
            wSprite = wImage
            hSprite = hImage
            -- print(strfmt("width: %d\nheight: %d", wImage, hImage))

            -- Word 2.
            local planesStr = strsub(binData, cursor + 16, cursor + 16)
            -- local maskStr = strsub(binData, cursor + 17, cursor + 17)
            local comprStr = strsub(binData, cursor + 18, cursor + 18)

            -- Word 3.
            planes = strunpack(">I1", planesStr)
            -- masking = strunpack(">I1", maskStr)
            compressed = strunpack(">I1", comprStr)
            isTrueColor24 = planes == 24
            isTrueColor32 = planes == 32
            print(strfmt(
                "planes: %d\nmasking: %d\ncompressed: %d",
                planes, masking, compressed))

            -- if isTrueColor24 or isTrueColor32 then
            --     print("True color image.")
            -- end

            -- Word 4.
            local trclStr = strsub(binData, cursor + 20, cursor + 21)
            local xAspStr = strsub(binData, cursor + 22, cursor + 22)
            local yAspStr = strsub(binData, cursor + 23, cursor + 23)
            alphaIndex = strunpack(">I2", trclStr)
            xAspect = strunpack(">I1", xAspStr)
            yAspect = strunpack(">I1", yAspStr)
            -- print(strfmt("alphaIndex: %d", alphaIndex))
            -- print(strfmt("xAspect: %d", xAspect))
            -- print(strfmt("yAspect: %d", yAspect))

            -- Word 5.
            local pgwStr = strsub(binData, cursor + 24, cursor + 25)
            local pghStr = strsub(binData, cursor + 26, cursor + 27)
            wSprite = strunpack(">I2", pgwStr)
            hSprite = strunpack(">I2", pghStr)
            -- print(strfmt("wSprite: %d\nhSprite: %d", wSprite, hSprite))
            if wSprite == 0 then wSprite = wImage end
            if hSprite == 0 then hSprite = hImage end

            chunkLen = 8 + lenLocal
        elseif headerlc == "cmap" then
            -- print(strfmt("\nCMAP found. Cursor: %d.", cursor))
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("lenLocal: %d", lenLocal))

            local numColors = lenLocal // 3
            -- print(strfmt("numColors: %d", numColors))
            local i = 0
            while i < numColors do
                local i3 = i * 3
                local r8 = strbyte(binData, cursor + 8 + i3)
                local g8 = strbyte(binData, cursor + 9 + i3)
                local b8 = strbyte(binData, cursor + 10 + i3)
                i = i + 1
                aseColors[i] = Color { r = r8, g = g8, b = b8, a = 255 }

                -- print(strfmt("%03d: %03d %03d %03d, #%06x",
                --     i - 1, r8, g8, b8, r8 << 0x10 | g8 << 0x08 | b8))
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "camg" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nCAMG found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            local flagsStr = strsub(binData, cursor + 8, cursor + 11)
            local flags = strunpack(">I4", flagsStr)
            -- print(strfmt("flags: %d, 0x%04x", flags, flags))

            isHighRes = (flags & 0x8000) ~= 0
            isHam = (flags & 0x800) ~= 0
            isExtraHalf = (flags & 0x80) ~= 0
            isInterlaced = (flags & 0x4) ~= 0

            -- if isHighRes then print("High res.") end
            -- if isHam then print("HAM.") end
            -- if isExtraHalf then print("Extra Half Bright") end
            -- if isInterlaced then print("Interlaced") end

            chunkLen = 8 + lenLocal
        elseif headerlc == "drng" then
            -- https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap#ILBM.DRNG
            -- TODO: Found in sample file "DLDLabel.ham".
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDRNG found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "ccrt" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nCCRT found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            local dirStr = strsub(binData, cursor + 8, cursor + 9)
            local dir = strunpack(">i2", dirStr)
            -- print(strfmt("dir: %d", dir))

            if dir ~= 0 then
                local origStr = strsub(binData, cursor + 10, cursor + 10)
                local destStr = strsub(binData, cursor + 11, cursor + 11)

                local orig = strunpack(">I1", origStr)
                local dest = strunpack(">I1", destStr)

                local span = 1 + dest - orig
                if span > 1 then
                    -- 1 sec = 1000 milisec = 1000000 microsec.
                    local secsStr = strsub(binData, cursor + 12, cursor + 15)
                    local microStr = strsub(binData, cursor + 16, cursor + 19)

                    local seconds = strunpack(">I4", secsStr)
                    local micros = strunpack(">I4", microStr)
                    if seconds > 0 or micros > 0 then
                        -- print(strfmt(
                        --     "orig: %d,\ndest: %d\nseconds: %d\nmicros: %d",
                        --     orig, dest, seconds, micros))

                        local duration = seconds + micros * 0.000001
                        sumDuration = sumDuration + duration
                        -- print(strfmt(
                        --     "duration: %.6s, %dms",
                        --     duration, floor(0.5 + duration * 1000.0)))

                        colorCycles[#colorCycles + 1] = {
                            orig = orig,
                            dest = dest,
                            span = span,
                            duration = duration,
                            isReverse = dir < 0
                        }
                    end
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "crng" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nCRNG found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            local flagsStr = strsub(binData, cursor + 12, cursor + 13)
            local flags = strunpack(">I2", flagsStr)
            -- print(strfmt("flags: %d 0x%04x", flags, flags))
            -- if ((flags >> 1) & 1) ~= 0 then
            -- print("isReversed")
            -- end

            -- In many test files, CRNG tags contain crud data, such as zero
            -- flags, orig and dest being equal, or rate being zero.
            if (flags & 1) ~= 0 then
                local origStr = strsub(binData, cursor + 14, cursor + 14)
                local destStr = strsub(binData, cursor + 15, cursor + 15)

                local orig = strunpack(">I1", origStr)
                local dest = strunpack(">I1", destStr)

                -- print(strfmt("orig: %d,\ndest: %d", orig, dest))

                local span = 1 + dest - orig
                if span > 1 then
                    local rateStr = strsub(binData, cursor + 10, cursor + 11)
                    local rate = strunpack(">I2", rateStr)

                    -- "One popular paint package always sets the RNG_ACTIVE
                    -- bit, but uses a rate of 36 (decimal) to indicate cycling
                    -- is not active."
                    if rate > 0 and rate ~= 36 then
                        -- 16384 = 60 fps
                        -- duration in seconds: 16384 / (rate * 60)
                        local duration = 273.06666666667 / rate
                        sumDuration = sumDuration + duration

                        -- print(strfmt(
                        --     "rate: %d, duration: %.6s, %dms",
                        --     rate, duration, floor(0.5 + duration * 1000.0)))

                        colorCycles[#colorCycles + 1] = {
                            orig = orig,
                            dest = dest,
                            span = span,
                            duration = duration,
                            isReverse = ((flags >> 1) & 1) ~= 0
                        }
                    end
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "body" then
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nBODY found. Cursor: %d.\nlenLocal: %d",
            --     cursor, lenLocal))

            bodyFound = true

            -- CAMG chunk may be missing entirely, or occur before CMAP chunk,
            -- so this needs to wait until body to figure out...
            -- if wImage >= 640 then isHighRes = true end
            -- if hImage >= 400 then isInterlaced = true end

            if wImage >= 640 and hImage >= 400
                and (xAspect / yAspect) > 1.4142 then
                -- print("Fudge aspect ratio.")
                xAspect = 1
                yAspect = 1
            end

            if isExtraHalf then
                local i = 0
                while i < 32 do
                    i = i + 1
                    local aseColor = aseColors[i]
                    aseColors[32 + i] = Color {
                        r = aseColor.red // 2,
                        g = aseColor.green // 2,
                        b = aseColor.blue // 2,
                        a = 255
                    }
                end
            end

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
                -- print(strfmt("Decompressed: %d", #bytes))
            end

            if isPbm then
                pixels = bytes
            else
                local wordsPerRow = math.ceil(wImage / 16)
                local widthPlanes = wImage * planes
                local len3 = hImage * widthPlanes
                local filler = isTrueColor24 and 0xff000000 or 0
                local k = 0
                while k < len3 do
                    local y = k // widthPlanes
                    local n = k % widthPlanes
                    local z = n // wImage
                    local x = n % wImage

                    local flatWord = (z + y * planes) * wordsPerRow
                    local xFlr = x // 16
                    local idxChar = (xFlr + flatWord) * 2
                    local byte1 = bytes[1 + idxChar]
                    local byte2 = bytes[2 + idxChar]
                    local word = (byte1 << 0x08) | byte2

                    local xRem = x % 16
                    local shift = 15 - xRem
                    local bit = (word >> shift) & 1

                    local idx = 1 + x + y * wImage
                    local hex = pixels[idx]
                    if hex then
                        pixels[idx] = hex | (bit << z)
                    else
                        pixels[idx] = filler | (bit << z)
                    end
                    k = k + 1
                end
            end

            chunkLen = 8 + lenLocal
        elseif headerlc == "abit" then
            -- TODO:
            -- https://wiki.multimedia.cx/index.php/IFF#ACBM_and_ABIT
            -- https://wiki.amigaos.net/wiki/ACBM_IFF_Amiga_Continuous_Bitmap
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            print(strfmt("\nABIT found. Cursor: %d.\nlenLocal: %d",
                cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "anhd" then
            -- https://wiki.amigaos.net/wiki/ANIM_IFF_CEL_Animations#ANHD
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nANHD found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "anno" then
            -- Annotation.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nANNO found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "auth" then
            -- Author.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nAUTH found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dlta" then
            -- https://wiki.amigaos.net/wiki/ANIM_IFF_CEL_Animations#DLTA
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDLTA found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))
            chunkLen = 8 + lenLocal
        elseif headerlc == "dpan" then
            -- https://wiki.amigaos.net/wiki/ANIM_IFF_CEL_Animations#DPAN
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDPAN found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            local frCountStr = strsub(binData, cursor + 10, cursor + 11)
            maxFrames = strunpack(">I2", frCountStr)
            -- print(strfmt("frCount: %d", maxFrames))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dpi " then
            -- Divets per inch.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDPI found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dpps" then
            -- Don't know what this is, but it's found in the King Tut image.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDPPS found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "dppv" then
            -- Perspective and transformation.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nDDPV found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal
        elseif headerlc == "tiny" then
            -- Thumbnail.
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nTINY found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            chunkLen = 8 + lenLocal

            -- Some Mark Ferrari files have extra zeroes at the end of tiny
            -- chunks which make it hard to find body.
            while strbyte(binData, cursor + chunkLen) == 0 do
                chunkLen = chunkLen + 1
            end
        elseif headerlc == "xbmi" then
            -- https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap#ILBM.XBMI
            local lenStr = strsub(binData, cursor + 4, cursor + 7)
            local lenLocal = strunpack(">I4", lenStr)
            -- print(strfmt("\nXBMI found. Cursor: %d\nlenLocal: %d",
            --     cursor, lenLocal))

            -- 0 PALETTE
            -- 1 GRAY black = 0, white = (1 << depth) - 1
            -- 2 RGB bits per sample = depth / 3, samples per pixel = 3.
            -- 3 RGBA bits per sample = depth / 4, samples per pixel = 4.
            -- 4 CMYK
            -- 5 CMYKA
            -- 6 Black or white
            local clrFmtStr = strsub(binData, cursor + 8, cursor + 9)
            local clrFmtFlag = strunpack(">I2", clrFmtStr)
            if clrFmtFlag == 2 then isTrueColor24 = true end
            if clrFmtFlag == 3 then isTrueColor32 = true end
            -- print(strfmt("clrFmt: %d, 0x%04x", clrFmtFlag, clrFmtFlag))

            chunkLen = 8 + lenLocal
        else
            -- Some files will fill with junk data beyond the length
            -- specified by the form.
            if cursor <= lenForm + 8
                and currFrame <= maxFrames
                and #headerlc >= 4 then
                chunkLen = 4

                print(strfmt("Unexpected found. Cursor: %d. Header:  %s",
                    cursor, headerlc))
                return nil
            end
        end

        cursor = cursor + chunkLen
    end

    local xaReduced = 1
    local yaReduced = 1
    if xAspect ~= 0 and yAspect ~= 0 then
        xaReduced, yaReduced = reduceRatio(xAspect, yAspect)
    end
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
    -- print(strfmt("\nlenColorCycles: %d", lenColorCycles))
    if lenColorCycles > 0 then
        -- TODO: Do color cycling indices work differently for extra half brite?
        local avgDuration = sumDuration / lenColorCycles
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
        -- print(strfmt("Least common multiple: %d", requiredFrames))

        if requiredFrames <= defaults.maxFrames then
            -- Copy still image to new frames.
            app.transaction(function()
                local g = 1
                while g < requiredFrames do
                    g = g + 1
                    local frObj = sprite:newEmptyFrame()
                    frObj.duration = avgDuration
                    sprite:newCel(activeLayer, frObj, stillImage)
                end
                sprite.frames[1].duration = avgDuration
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
            app.frame = sprite.frames[1]
            app.command.FitScreen()
            app.refresh()
        end
    end
}

dlg:separator { id = "exportSep" }

dlg:check {
    id = "useCompress",
    label = "Compress:",
    selected = defaults.useCompress,
    focus = false
}

dlg:newrow { always = false }

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

        local useCompress = args.useCompress --[[@as boolean]]
        local fileExt = string.lower(app.fs.fileExtension(exportFilepath))
        local isPbm = fileExt == "lbm"
        local binStr = writeFile(activeSprite, activeFrame, isPbm, useCompress)
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
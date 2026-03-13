--[[
Rime 辅码过滤器 (Aux Code Filter)
功能：
- 根据输入的辅码字符串（最多两个字符）筛选候选词。
- 支持两种触发模式："learn"（学习模式）和 "no_learn"（不学习模式），通过配置的触发键区分。
- 筛选逻辑：
  * 辅码长度=1：检查该字符是否在词首字的首辅码键集合中。
  * 辅码长度=2：先尝试完整匹配首字的某个辅码，再尝试首尾字首键整体匹配（仅当词长>1时）。
- 显示单字的辅码注释（可选）。
- 在选词上屏过程中自动维持辅码分隔符，直到所有字母上屏完毕。
- 当辅码词典文件缺失时，在首个候选项上给出提示。
- 词典路径可通过配置 `aux_code/dict` 自定义（相对 Rime 用户目录），默认路径为 `aux_code/{命名空间}.txt`。
]]

local AuxFilter = {}

-- 模块级缓存，避免重复读取词典文件
local cache = {}

-- 辅助函数：规范化触发键（空值或 nil 则返回 fallback）
local function normalize_trigger(token, fallback)
    if token == nil or token == "" then
        return fallback
    end
    return token
end

-- 构建词典缺失提示信息
local function build_missing_dict_message(filename)
    return "(⚠️config/rime/aux_code/ 中未找到辅码文件 " .. filename .. ")"
end

-- 合并注释，避免重复追加相同内容
local function merge_comment(origin, message)
    if not origin or origin == "" then
        return message
    end
    if origin:find(message, 1, true) then
        return origin
    end
    return origin .. " | " .. message
end

-- 为候选添加缺失提示（处理 ShadowCandidate）
local function append_missing_hint(cand, message)
    if not message or message == "" then
        return cand
    end

    if cand:get_dynamic_type() == "Shadow" then
        local shadow_text = cand.text
        local shadow_comment = cand.comment or ""
        local original = cand:get_genuine()
        if not original then
            cand.comment = merge_comment(cand.comment, message)
            return cand
        end
        local merged = merge_comment((original.comment or "") .. shadow_comment, message)
        return ShadowCandidate(original, original.type, shadow_text, merged)
    end

    cand.comment = merge_comment(cand.comment, message)
    return cand
end

-- 转义 Lua 模式字符串中的特殊字符
local function escape_lua_pattern(text)
    return text:gsub("%W", "%%%1")
end

-- 解析输入字符串，判断触发模式并提取辅码字符串（最多两个字符）
-- 返回：mode（"learn"/"no_learn"/"none"）, auxStr（提取的辅码部分）, token（使用的触发键）
local function parse_aux_input(input_code, env)
    if input_code == "" then
        return "none", "", ""
    end

    for _, item in ipairs(env.triggers) do
        local token = item.token
        if token ~= "" then
            local token_pattern = escape_lua_pattern(token)
            if input_code:find(token, 1, true) then
                local local_split = input_code:match(token_pattern .. "([^,]+)")
                if not local_split then
                    return item.mode, "", token
                end
                return item.mode, string.sub(local_split, 1, 2), token
            end
        end
    end

    return "none", "", ""
end

-- 将候选转换为普通候选（可用于 "no_learn" 模式，避免用户词典记录）
local function to_commit_only_candidate(cand)
    local rebuilt = Candidate(cand.type, cand.start, cand._end, cand.text, cand.comment)
    rebuilt.preedit = cand.preedit
    rebuilt.quality = cand.quality
    return rebuilt
end

-- 读取辅码词典文件（格式：key=value，value 中多个辅码以空格分隔）
-- 参数：file_absolute_path - 文件的绝对路径
-- 返回：辅码表 { [字] = "辅码1 辅码2 ..." }，若失败返回 nil
function AuxFilter.readAuxTxt(file_absolute_path)
    if cache[file_absolute_path] then
        return cache[file_absolute_path]
    end

    local file = io.open(file_absolute_path, "r")
    if not file then
        return nil
    end

    local auxCodes = {}
    for line in file:lines() do
        line = line:match("[^\r\n]+") -- 去除换行符
        local key, value = line:match("([^=]+)=(.+)")
        if key and value then
            if auxCodes[key] then
                auxCodes[key] = auxCodes[key] .. " " .. value
            else
                auxCodes[key] = value
            end
        end
    end
    file:close()

    cache[file_absolute_path] = auxCodes
    return auxCodes
end

-- 计算词语的辅码相关信息
-- 返回表：{
--   firstCharFirstKeys = "首字首键集合（去重排序后字符串）",
--   lastCharFirstKeys  = "尾字首键集合（去重排序后字符串）",
--   firstCharFullCodes = { "完整辅码1", "完整辅码2", ... },
--   charCount          = 词语长度（字符数）
-- }
function AuxFilter.fullAux(env, word)
    local firstCharFirstKeys = {}
    local lastCharFirstKeys = {}
    local firstCharFullCodes = {}

    local chars = {}
    for _, codePoint in utf8.codes(word) do
        table.insert(chars, utf8.char(codePoint))
    end
    local charCount = #chars

    if charCount == 0 then
        return {
            firstCharFirstKeys = "",
            lastCharFirstKeys = "",
            firstCharFullCodes = {},
            charCount = 0
        }
    end

    -- 首字
    local firstChar = chars[1]
    local firstCharAuxCodes = env.aux_code[firstChar]
    if firstCharAuxCodes then
        for code in firstCharAuxCodes:gmatch("%S+") do
            if #code >= 1 then
                local firstKey = code:sub(1, 1)
                firstCharFirstKeys[firstKey] = true
            end
            table.insert(firstCharFullCodes, code)
        end
    end

    -- 尾字（若与首字不同）
    if charCount > 1 then
        local lastChar = chars[charCount]
        local lastCharAuxCodes = env.aux_code[lastChar]
        if lastCharAuxCodes then
            for code in lastCharAuxCodes:gmatch("%S+") do
                if #code >= 1 then
                    local firstKey = code:sub(1, 1)
                    lastCharFirstKeys[firstKey] = true
                end
            end
        end
    end

    -- 将键集合转为排序后的字符串
    local function keys_to_string(t)
        local keys = {}
        for k, _ in pairs(t) do
            table.insert(keys, k)
        end
        table.sort(keys)
        return table.concat(keys, "")
    end

    return {
        firstCharFirstKeys = keys_to_string(firstCharFirstKeys),
        lastCharFirstKeys = keys_to_string(lastCharFirstKeys),
        firstCharFullCodes = firstCharFullCodes,
        charCount = charCount
    }
end

-- 判断辅码字符串 auxStr 是否与 fullAux 匹配
-- 返回：matched (boolean), matchType ("full"/"global"/nil)
function AuxFilter.match(fullAux, auxStr)
    if #auxStr == 0 then
        return false, nil
    end

    local len = #auxStr
    if len == 1 then
        -- 单字符：是否在首字首键集合中
        if fullAux.firstCharFirstKeys:find(auxStr, 1, true) then
            return true, "global"
        end
        return false, nil
    elseif len == 2 then
        -- 先尝试完整匹配首字辅码
        for _, code in ipairs(fullAux.firstCharFullCodes) do
            if code == auxStr then
                return true, "full"
            end
        end
        -- 再尝试整体词组匹配（仅当词长 > 1）
        if fullAux.charCount > 1 then
            if fullAux.firstCharFirstKeys:find(auxStr:sub(1, 1), 1, true) and
               fullAux.lastCharFirstKeys:find(auxStr:sub(2, 2), 1, true) then
                return true, "global"
            end
        end
        return false, nil
    else
        -- auxStr 长度不可能大于2，但安全处理
        return false, nil
    end
end

-- 过滤器初始化
function AuxFilter.init(env)
    local engine = env.engine
    local config = engine.schema.config

    -- 获取词典路径配置（相对 Rime 用户目录）
    local dict_rel_path = config:get_string("aux_code/dict")
    local user_dir = rime_api.get_user_data_dir()
    local dict_abs_path
    local dict_display_name

    if dict_rel_path then
        -- 去除开头的路径分隔符，避免重复
        dict_rel_path = dict_rel_path:gsub("^[/\\]", "")
        dict_abs_path = user_dir .. "/" .. dict_rel_path
        dict_display_name = dict_rel_path
    else
        -- 默认路径
        local default_dir = "aux_code"
        local default_filename = env.name_space .. ".txt"
        dict_abs_path = user_dir .. "/" .. default_dir .. "/" .. default_filename
        dict_display_name = default_dir .. "/" .. default_filename
    end

    -- 加载辅码词典
    local aux_code = AuxFilter.readAuxTxt(dict_abs_path)
    if aux_code then
        env.aux_code = aux_code          -- 词典存入环境
        env.aux_ready = true
        env.aux_error_msg = nil
    else
        env.aux_code = {}
        env.aux_ready = false
        env.aux_error_msg = build_missing_dict_message(dict_display_name)
        -- 可在此输出日志
    end

    -- 获取触发键配置
    env.learn_trigger = normalize_trigger(config:get_string("key_binder/aux_code_learn_trigger"), nil)
        or normalize_trigger(config:get_string("key_binder/aux_code_trigger"), nil)
        or ";"
    env.no_learn_trigger = normalize_trigger(config:get_string("key_binder/aux_code_no_learn_trigger"), "")

    if env.no_learn_trigger == env.learn_trigger then
        env.no_learn_trigger = ""
    end

    env.triggers = {
        { mode = "no_learn", token = env.no_learn_trigger },
        { mode = "learn",    token = env.learn_trigger },
    }

    -- 过滤掉空触发键，并按长度降序排序（长键优先匹配）
    local active_triggers = {}
    for _, item in ipairs(env.triggers) do
        if item.token ~= "" then
            table.insert(active_triggers, item)
        end
    end
    env.triggers = active_triggers
    table.sort(env.triggers, function(a, b) return #a.token > #b.token end)

    -- 兼容旧逻辑
    env.trigger_key = env.learn_trigger

    -- 是否显示辅码注释
    local show = config:get_string("key_binder/show_aux_notice") or 'true'
    env.show_aux_notice = show ~= "false"

    -- 选词上屏后维持辅码分隔符的逻辑
    env.notifier = engine.context.select_notifier:connect(function(ctx)
        local mode, _, trigger_token = parse_aux_input(ctx.input, env)
        if mode == "none" then
            return
        end

        local preedit = ctx:get_preedit()
        local trigger_pattern = trigger_token:gsub("%W", "%%%1")
        local removeAuxInput = ctx.input:match("([^,]+)" .. trigger_pattern)
        local reeditTextFront = preedit.text:match("([^,]+)" .. trigger_pattern)

        if not removeAuxInput then
            return
        end

        -- 更新输入字符串：去掉已上屏部分和辅码分隔符
        ctx.input = removeAuxInput
        if reeditTextFront and reeditTextFront:match("[a-z]") then
            -- 若还有字母未上屏，则补回分隔符，以便继续输入辅码
            ctx.input = ctx.input .. trigger_token
        else
            -- 所有字母均已上屏，直接提交
            ctx:commit()
        end
    end)
end

-- 过滤器主函数
function AuxFilter.func(input, env)
    local context = env.engine.context
    local inputCode = context.input

    local mode, auxStr, _ = parse_aux_input(inputCode, env)

    -- 没有触发键：直接输出所有候选（性能优化）
    if mode == "none" then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 词典加载失败：仅对首个候选项添加提示后输出所有候选
    if not env.aux_ready then
        local should_hint = #auxStr == 0
        local hinted = false
        for cand in input:iter() do
            if should_hint and not hinted then
                cand = append_missing_hint(cand, env.aux_error_msg)
                hinted = true
            end
            yield(cand)
        end
        return
    end

    -- 根据匹配类型收集候选
    local full_matches = {}   -- 完整匹配首字辅码的候选
    local global_matches = {} -- 整体匹配的候选

    for cand in input:iter() do
        -- 单字辅码（用于显示注释）
        local singleCharAux = env.aux_code[cand.text]
        local fullAux = AuxFilter.fullAux(env, cand.text)

        -- 添加辅码注释（如果启用）
        if env.show_aux_notice and singleCharAux and #singleCharAux > 0 then
            local codeComment = singleCharAux:gsub(' ', ',')
            if cand:get_dynamic_type() == "Shadow" then
                local shadowText = cand.text
                local shadowComment = cand.comment or ""
                local original = cand:get_genuine()
                cand = ShadowCandidate(original, original.type, shadowText,
                    (original.comment or "") .. shadowComment .. '(' .. codeComment .. ')')
            else
                cand.comment = '(' .. codeComment .. ')'
            end
        end

        -- 无辅码输入：根据模式决定是否转换为普通候选后输出
        if #auxStr == 0 then
            if mode == "no_learn" then
                yield(to_commit_only_candidate(cand))
            else
                yield(cand)
            end
        else
            local matched, matchType = AuxFilter.match(fullAux, auxStr)
            if matched then
                local target_cand = cand
                if mode == "no_learn" then
                    target_cand = to_commit_only_candidate(cand)
                end
                if matchType == "full" then
                    table.insert(full_matches, target_cand)
                else -- "global"
                    table.insert(global_matches, target_cand)
                end
            end
            -- 不匹配的候选直接丢弃
        end
    end

    -- 输出顺序：先整体匹配，后完整匹配（与原逻辑保持一致）
    for _, cand in ipairs(global_matches) do
        yield(cand)
    end
    for _, cand in ipairs(full_matches) do
        yield(cand)
    end
end

-- 清理资源
function AuxFilter.fini(env)
    if env.notifier then
        env.notifier:disconnect()
    end
end

return AuxFilter

-- Local Variables:
-- lua-indent-level: 4
-- End:
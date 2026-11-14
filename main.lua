local mod = RegisterMod("One Last Hand", 1)
local json = require("json")

mod.COLLECTIBLE_ONE_LAST_HAND = Isaac.GetItemIdByName("One Last Hand")

local function log(msg)
    print("[One Last Hand] " .. msg)
    Isaac.DebugString("[One Last Hand] " .. msg)
end

log("Mod loaded. Item ID = " .. tostring(mod.COLLECTIBLE_ONE_LAST_HAND))

---------------------------------------------------------------------
-- Pickup classification (all IDs verified in-game via CARDDUMP)
---------------------------------------------------------------------
local WILDCARD_IDS = {
    [31] = true, -- Joker
    [48] = true, -- ? Card
    [80] = true, -- Wild Card
    [40] = true, -- Blank Rune
}
local RUNE_SHARD_ID = 55
local HORSE_PILL_FLAG = 2048 -- verified: horse pill subtype = colour + 2048
local GOLD_PILL_COLOUR = 14  -- verified: spawn 5.70.14 is the golden pill

local function classifyCard(id)
    if WILDCARD_IDS[id] then
        return { family = "WILD", identity = "WILD:" .. id, units = 1, wild = true }
    end

    if id >= 1 and id <= 22 then
        return { family = "TAROT", identity = "TAROT:" .. id, units = 1, arcana = id }
    end

    if id >= 56 and id <= 77 then
        local base = id - 55 -- reversed counts as its upright counterpart
        return { family = "TAROT", identity = "TAROT:" .. base, units = 1, arcana = base }
    end

    if id == RUNE_SHARD_ID then
        return { family = "RUNE", identity = "RUNE:SHARD", units = 1 }
    end

    if id >= 32 and id <= 41 then
        return { family = "RUNE", identity = "RUNE:" .. id, units = 1 }
    end

    if id >= 81 and id <= 97 then
        return { family = "SOUL", identity = "SOUL:" .. id, units = 1 }
    end

    return nil
end

local function classifyPill(subType)
    local isHorse = subType >= HORSE_PILL_FLAG
    local colour = subType % HORSE_PILL_FLAG

    if colour == GOLD_PILL_COLOUR then
        return { family = "WILD", identity = "WILD:GOLDPILL", units = 1, wild = true }
    end

    return {
        family = "PILL",
        identity = "PILL:" .. colour,
        units = isHorse and 2 or 1,
    }
end

---------------------------------------------------------------------
-- Room scan
---------------------------------------------------------------------
local function collectEligible()
    local entries = {}
    for _, ent in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP, -1, -1)) do
        local pickup = ent:ToPickup()
        if pickup and pickup.Price == 0 then
            local info
            if pickup.Variant == PickupVariant.PICKUP_TAROTCARD then
                info = classifyCard(pickup.SubType)
            elseif pickup.Variant == PickupVariant.PICKUP_PILL then
                info = classifyPill(pickup.SubType)
            end
            if info then
                info.pickup = pickup
                table.insert(entries, info)
            end
        end
    end
    return entries
end


---------------------------------------------------------------------
-- HAND EVALUATOR
---------------------------------------------------------------------

local HAND_RANK = {
    PAIR = 1,
    TWO_PAIR = 2,
    THREE_OF_A_KIND = 3,
    FLUSH = 4,
    FULL_HOUSE = 5,
    FOUR_OF_A_KIND = 6,
    FIVE_OF_A_KIND = 7,
    ARCANA_RUN = 8,
    ROYAL_FLUSH = 9,
}

local function isWildcard(entry)
    return entry.wild == true or entry.isWildcard == true
end

local function findExactSubset(list, target)
    local ordered = {}

    for _, entry in ipairs(list) do
        if entry.units <= target then
            table.insert(ordered, entry)
        end
    end

    table.sort(ordered, function(a, b)
        if a.units ~= b.units then
            return a.units > b.units
        end

        return a.pickup.InitSeed < b.pickup.InitSeed
    end)

    local dp = {
        [0] = {},
    }

    for _, entry in ipairs(ordered) do
        for total = target - entry.units, 0, -1 do
            local newTotal = total + entry.units

            if dp[total] and not dp[newTotal] then
                local selection = {}

                for _, selected in ipairs(dp[total]) do
                    table.insert(selection, selected)
                end

                table.insert(selection, entry)
                dp[newTotal] = selection
            end
        end
    end

    return dp[target]
end


---------------------------------------------------------------------
-- CANDIDATE COMPARISON
---------------------------------------------------------------------

local function makeCandidate(rank, name, selected)
    local unique = {}
    local seen = {}

    for _, entry in ipairs(selected) do
        if not seen[entry.pickup] then
            seen[entry.pickup] = true
            table.insert(unique, entry)
        end
    end

    local wildCount = 0
    local signatureParts = {}

    for _, entry in ipairs(unique) do
        if isWildcard(entry) then
            wildCount = wildCount + 1
        end

        table.insert(
            signatureParts,
            tostring(entry.identity) .. ":" ..
            tostring(entry.pickup.InitSeed)
        )
    end

    if wildCount > 1 then
        return nil
    end

    table.sort(signatureParts)

    return {
        rank = rank,
        name = name,
        selected = unique,
        wildCount = wildCount,
        signature = table.concat(signatureParts, "|"),
    }
end


local function chooseBetter(current, candidate)
    if not candidate then
        return current
    end

    if not current then
        return candidate
    end

    if candidate.rank ~= current.rank then
        return candidate.rank > current.rank and candidate or current
    end

    if candidate.wildCount ~= current.wildCount then
        return candidate.wildCount < current.wildCount
            and candidate or current
    end

    if #candidate.selected ~= #current.selected then
        return #candidate.selected < #current.selected
            and candidate or current
    end

    return candidate.signature < current.signature
        and candidate or current
end


---------------------------------------------------------------------
-- EVALUATE A SET OF ENTRIES WITH FIXED IDENTITIES
---------------------------------------------------------------------

local function evaluateAssigned(entries)
    local groups = {}
    local families = {}

    for _, entry in ipairs(entries) do
        groups[entry.identity] = groups[entry.identity] or {}
        table.insert(groups[entry.identity], entry)

        families[entry.family] = families[entry.family] or {}
        table.insert(families[entry.family], entry)
    end

    local identities = {}

    for identity in pairs(groups) do
        table.insert(identities, identity)
    end

    table.sort(identities)

    local best = nil

    local function submit(rank, name, selected)
        local candidate = makeCandidate(rank, name, selected)
        best = chooseBetter(best, candidate)
    end

    for _, identity in ipairs(identities) do
        local group = groups[identity]

        local five = findExactSubset(group, 5)
        if five then
            submit(HAND_RANK.FIVE_OF_A_KIND, "FIVE OF A KIND", five)
        end

        local four = findExactSubset(group, 4)
        if four then
            submit(HAND_RANK.FOUR_OF_A_KIND, "FOUR OF A KIND", four)
        end

        local three = findExactSubset(group, 3)
        if three then
            submit(HAND_RANK.THREE_OF_A_KIND, "THREE OF A KIND", three)
        end

        local pair = findExactSubset(group, 2)
        if pair then
            submit(HAND_RANK.PAIR, "PAIR", pair)
        end
    end

    for i = 1, #identities do
        local firstPair = findExactSubset(groups[identities[i]], 2)

        if firstPair then
            for j = i + 1, #identities do
                local secondPair = findExactSubset(groups[identities[j]], 2)

                if secondPair then
                    local selected = {}

                    for _, entry in ipairs(firstPair) do
                        table.insert(selected, entry)
                    end

                    for _, entry in ipairs(secondPair) do
                        table.insert(selected, entry)
                    end

                    submit(HAND_RANK.TWO_PAIR, "TWO PAIR", selected)
                end
            end
        end
    end

    for i = 1, #identities do
        local triple = findExactSubset(groups[identities[i]], 3)

        if triple then
            for j = 1, #identities do
                if i ~= j then
                    local pair = findExactSubset(groups[identities[j]], 2)

                    if pair then
                        local selected = {}

                        for _, entry in ipairs(triple) do
                            table.insert(selected, entry)
                        end

                        for _, entry in ipairs(pair) do
                            table.insert(selected, entry)
                        end

                        submit(HAND_RANK.FULL_HOUSE, "FULL HOUSE", selected)
                    end
                end
            end
        end
    end

    for _, family in ipairs({"TAROT", "PILL", "RUNE", "SOUL"}) do
        local subset = findExactSubset(families[family] or {}, 5)

        if subset then
            submit(HAND_RANK.FLUSH, "FLUSH", subset)
        end
    end

    for start = 1, 18 do
        local selected = {}
        local valid = true

        for id = start, start + 4 do
            local group = groups["TAROT:" .. id] or {}
            local subset = findExactSubset(group, 1)

            if not subset then
                valid = false
                break
            end

            table.insert(selected, subset[1])
        end

        if valid then
            submit(HAND_RANK.ARCANA_RUN, "ARCANA RUN", selected)
        end
    end

    local royalCards = {18, 19, 20, 21, 22}
    local royalSelection = {}
    local royalValid = true

    for _, id in ipairs(royalCards) do
        local group = groups["TAROT:" .. id] or {}
        local subset = findExactSubset(group, 1)

        if not subset then
            royalValid = false
            break
        end

        table.insert(royalSelection, subset[1])
    end

    if royalValid then
        submit(HAND_RANK.ROYAL_FLUSH, "ROYAL FLUSH", royalSelection)
    end

    return best
end


---------------------------------------------------------------------
-- WILDCARD ASSIGNMENT
---------------------------------------------------------------------

local function getBestHand(entries)
    local normal = {}
    local wildcards = {}

    for _, entry in ipairs(entries) do
        if isWildcard(entry) then
            table.insert(wildcards, entry)
        else
            table.insert(normal, entry)
        end
    end

    local best = evaluateAssigned(normal)

    if #wildcards == 0 then
        return best
    end

    table.sort(wildcards, function(a, b)
        return a.pickup.InitSeed < b.pickup.InitSeed
    end)

    local wildcard = wildcards[1]

    local assignments = {}
    local assignmentSeen = {}

    local function addAssignment(family, identity, arcana)
        local key = family .. "|" .. identity

        if not assignmentSeen[key] then
            assignmentSeen[key] = true

            table.insert(assignments, {
                family = family,
                identity = identity,
                arcana = arcana,
            })
        end
    end

    for _, entry in ipairs(normal) do
        addAssignment(entry.family, entry.identity, entry.arcana)
    end

    for _, family in ipairs({"TAROT", "PILL", "RUNE", "SOUL"}) do
        addAssignment(family, "WILD_FLUSH:" .. family, nil)
    end

    for id = 1, 22 do
        addAssignment("TAROT", "TAROT:" .. id, id)
    end

    for _, assignment in ipairs(assignments) do
        local assigned = {}

        for _, entry in ipairs(normal) do
            table.insert(assigned, entry)
        end

        table.insert(assigned, {
            family = assignment.family,
            identity = assignment.identity,
            units = 1,
            arcana = assignment.arcana,
            pickup = wildcard.pickup,
            wild = true,
            isWildcard = true,
        })

        best = chooseBetter(best, evaluateAssigned(assigned))
    end

    return best
end


---------------------------------------------------------------------
-- DEVIL / ANGEL POOL WEIGHTS
---------------------------------------------------------------------

local function anyPlayerHasCollectible(id)
    local game = Game()

    for i = 0, game:GetNumPlayers() - 1 do
        local player = game:GetPlayer(i)

        if player and player:HasCollectible(id, false) then
            return true
        end
    end

    return false
end


local function anyPlayerHasTrinket(id)
    local game = Game()

    for i = 0, game:GetNumPlayers() - 1 do
        local player = game:GetPlayer(i)

        if player and player:HasTrinket(id, false) then
            return true
        end
    end

    return false
end


local function getDevilAngelShares()
    local game = Game()
    local level = game:GetLevel()
    local angelModifier = level:GetAngelRoomChance()

    local angelRoomSpawned =
        game:GetStateFlag(GameStateFlag.STATE_FAMINE_SPAWNED)

    local devilRoomSpawned =
        game:GetStateFlag(GameStateFlag.STATE_DEVILROOM_SPAWNED)

    local devilRoomVisited =
        game:GetStateFlag(GameStateFlag.STATE_DEVILROOM_VISITED)

    local hasVirtues =
        anyPlayerHasCollectible(CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES)

    local hasAct =
        anyPlayerHasCollectible(CollectibleType.COLLECTIBLE_ACT_OF_CONTRITION)

    local devilShare = 1.0

    if anyPlayerHasCollectible(CollectibleType.COLLECTIBLE_EUCHARIST) then
        devilShare = 0.0

    elseif devilRoomSpawned and devilRoomVisited
        and game:GetDevilRoomDeals() > 0 then

        if hasVirtues or hasAct or angelModifier > 0 then
            devilShare = 0.5
        end

    elseif devilRoomSpawned or hasVirtues or angelModifier > 0 then

        if not (devilRoomVisited or angelRoomSpawned) then
            devilShare = 0.0
        else
            devilShare = 0.5
        end
    end

    if devilShare == 0.5 then
        if anyPlayerHasTrinket(TrinketType.TRINKET_ROSARY_BEAD) then
            devilShare = devilShare * 0.5
        end

        if game:GetDonationModAngel() >= 10 then
            devilShare = devilShare * 0.5
        end

        if anyPlayerHasCollectible(CollectibleType.COLLECTIBLE_KEY_PIECE_1) then
            devilShare = devilShare * 0.75
        end

        if anyPlayerHasCollectible(CollectibleType.COLLECTIBLE_KEY_PIECE_2) then
            devilShare = devilShare * 0.75
        end

        if level:GetStateFlag(LevelStateFlag.STATE_EVIL_BUM_KILLED) then
            devilShare = devilShare * 0.75
        end

        if level:GetStateFlag(LevelStateFlag.STATE_BUM_LEFT)
            and not level:GetStateFlag(LevelStateFlag.STATE_EVIL_BUM_LEFT) then
            devilShare = devilShare * 0.9
        end

        if level:GetStateFlag(LevelStateFlag.STATE_EVIL_BUM_LEFT)
            and not level:GetStateFlag(LevelStateFlag.STATE_BUM_LEFT) then
            devilShare = devilShare * 1.1
        end

        if angelModifier > 0 or
            (angelModifier < 0 and (hasVirtues or hasAct)) then
            devilShare = devilShare * (1.0 - angelModifier)
        end

        if hasVirtues then
            devilShare = devilShare * 0.75
        end
    end

    devilShare = math.max(0.0, math.min(devilShare, 1.0))

    return devilShare, 1.0 - devilShare
end


---------------------------------------------------------------------
-- REWARD PREVIEW TEXT
---------------------------------------------------------------------

local function getRewardLines(hand)
    if not hand then
        return "NO VALID HAND", "Activation will do nothing"
    end

    if hand.name == "PAIR" then
        return "PAIR", "Reward: +1.0 Tears (permanent)"

    elseif hand.name == "TWO PAIR" then
        return "TWO PAIR", "Reward: +1.0 Damage (permanent)"

    elseif hand.name == "THREE OF A KIND" then
        return "THREE OF A KIND", "Reward: +1.0 Luck (permanent)"

    elseif hand.name == "FLUSH" then
        return "FLUSH", "Reward: Breakfast collectible pedestal"

    elseif hand.name == "FULL HOUSE" then
        return "FULL HOUSE", "Reward: duplicate all other eligible pickups"

    elseif hand.name == "FOUR OF A KIND" then
        return "FOUR OF A KIND", "Reward: choose 1 of 3 Treasure Room items"

    elseif hand.name == "FIVE OF A KIND" then
        return "FIVE OF A KIND", "Reward: choose 1 of 2 Secret Room items"

    elseif hand.name == "ARCANA RUN" then
        local devil, angel = getDevilAngelShares()

        return "ARCANA RUN",
            "2 free Devil/Angel items | Devil " ..
            tostring(math.floor(devil * 100 + 0.5)) ..
            "% / Angel " ..
            tostring(math.floor(angel * 100 + 0.5)) .. "%"

    elseif hand.name == "ROYAL FLUSH" then
        return "ROYAL FLUSH", "Reward: choose 1 Angel & 1 Devil item"

    else
        return hand.name, "Reward not implemented"
    end
end


---------------------------------------------------------------------
-- HUD PREVIEW
---------------------------------------------------------------------

local function renderCenteredText(text, y)
    local screenWidth = Isaac.GetScreenWidth()
    local textWidth = Isaac.GetTextWidth(text)
    local x = math.max(5, (screenWidth - textWidth) / 2)

    Isaac.RenderText(text, x + 1, y + 1, 0, 0, 0, 1)
    Isaac.RenderText(text, x, y, 1, 1, 1, 1)
end


function mod:OnPostRender()
    local game = Game()

    if game:IsPaused() then
        return
    end

    local owner = nil

    for i = 0, game:GetNumPlayers() - 1 do
        local player = game:GetPlayer(i)

        if player and player:HasCollectible(mod.COLLECTIBLE_ONE_LAST_HAND) then
            owner = player
            break
        end
    end

    if not owner then
        return
    end

    local hand = getBestHand(collectEligible())
    local line1, line2 = getRewardLines(hand)

    local y = Isaac.GetScreenHeight() - 42

    renderCenteredText(line1, y)
    renderCenteredText(line2, y + 10)
end

mod:AddCallback(ModCallbacks.MC_POST_RENDER, mod.OnPostRender)


---------------------------------------------------------------------
-- PERMANENT STAT BONUSES
---------------------------------------------------------------------

mod.runBonuses = {}

local function getPlayerKey(player)
    return tostring(player.ControllerIndex)
end


local function getPlayerBonuses(player)
    local key = getPlayerKey(player)

    if not mod.runBonuses[key] then
        mod.runBonuses[key] = {
            tears = 0,
            damage = 0,
            luck = 0,
        }
    end

    return mod.runBonuses[key]
end


local function saveBonuses()
    mod:SaveData(json.encode(mod.runBonuses))
end


function mod:OnGameStarted(isContinued)
    mod.runBonuses = {}

    if isContinued and mod:HasData() then
        local success, saved = pcall(json.decode, mod:LoadData())

        if success and type(saved) == "table" then
            mod.runBonuses = saved
        end
    end

    local game = Game()

    for i = 0, game:GetNumPlayers() - 1 do
        local player = game:GetPlayer(i)

        if player then
            player:AddCacheFlags(
                CacheFlag.CACHE_FIREDELAY |
                CacheFlag.CACHE_DAMAGE |
                CacheFlag.CACHE_LUCK
            )

            player:EvaluateItems()
        end
    end

    saveBonuses()
end

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, mod.OnGameStarted)


function mod:OnPreGameExit()
    saveBonuses()
end

mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, mod.OnPreGameExit)


function mod:OnEvaluateCache(player, cacheFlag)
    local bonus = getPlayerBonuses(player)

    if cacheFlag == CacheFlag.CACHE_DAMAGE then
        player.Damage = player.Damage + bonus.damage

    elseif cacheFlag == CacheFlag.CACHE_LUCK then
        player.Luck = player.Luck + bonus.luck

    elseif cacheFlag == CacheFlag.CACHE_FIREDELAY then
        local currentTears = 30 / (player.MaxFireDelay + 1)
        local newTears = math.min(currentTears + bonus.tears, 120)

        player.MaxFireDelay = 30 / newTears - 1
    end
end

mod:AddCallback(ModCallbacks.MC_EVALUATE_CACHE, mod.OnEvaluateCache)


local function addPermanentBonus(player, stat, amount)
    local bonus = getPlayerBonuses(player)

    bonus[stat] = bonus[stat] + amount

    player:AddCacheFlags(
        CacheFlag.CACHE_FIREDELAY |
        CacheFlag.CACHE_DAMAGE |
        CacheFlag.CACHE_LUCK
    )

    player:EvaluateItems()
    saveBonuses()
end


---------------------------------------------------------------------
-- REWARD PICKUP SPAWNING
---------------------------------------------------------------------

local function spawnCollectible(player, itemId, position, optionsIndex)
    local game = Game()
    local room = game:GetRoom()
    local spawnPosition = room:FindFreePickupSpawnPosition(position, 0, true, false)
    local seed = game:GetSeeds():GetNextSeed()

    if seed == 0 then
        seed = 1
    end

    local entity = game:Spawn(
        EntityType.ENTITY_PICKUP,
        PickupVariant.PICKUP_COLLECTIBLE,
        spawnPosition,
        Vector(0, 0),
        player,
        itemId,
        seed
    )

    if not entity then
        return nil
    end

    local pickup = entity:ToPickup()
    if pickup then
        pickup.Price = 0
        if optionsIndex and optionsIndex > 0 then
            pickup.OptionsPickupIndex = optionsIndex
        end
    end

    return pickup
end

local function spawnPoolItems(player, poolType, count, rng, optionsIndex)
    local game = Game()
    local room = game:GetRoom()
    local itemPool = game:GetItemPool()
    local spawned = {}

    for i = 1, count do
        local itemID = itemPool:GetCollectible(
            poolType,
            true,
            rng:Next()
        )

        local offset = Vector((i - (count + 1) / 2) * 54, 0)
        local desiredPosition = room:GetCenterPos() + offset
        local pickup = spawnCollectible(player, itemID, desiredPosition, optionsIndex)

        if not pickup then
            for _, existing in ipairs(spawned) do
                if existing:Exists() then
                    existing:Remove()
                end
            end

            return false
        end

        table.insert(spawned, pickup)
    end

    return true
end

local function spawnBreakfast(player)
    return spawnCollectible(
        player,
        CollectibleType.COLLECTIBLE_BREAKFAST,
        Game():GetRoom():GetCenterPos(),
        nil
    ) ~= nil
end

local function duplicateRemainingEligible(hand, player)
    local selected = {}

    for _, entry in ipairs(hand.selected) do
        selected[entry.pickup] = true
    end

    local entries = collectEligible()
    local room = Game():GetRoom()
    local duplicated = 0

    for _, entry in ipairs(entries) do
        local original = entry.pickup

        if original and original:Exists() and not selected[original] then
            local offset = Vector(((duplicated % 5) - 2) * 24, math.floor(duplicated / 5) * 24)
            local desiredPosition = original.Position + offset
            local position = room:FindFreePickupSpawnPosition(
                desiredPosition,
                0,
                true,
                false
            )

            local copy = Isaac.Spawn(
                EntityType.ENTITY_PICKUP,
                original.Variant,
                original.SubType,
                position,
                Vector(0, 0),
                player
            )

            if copy then
                duplicated = duplicated + 1
            end
        end
    end

    return true
end

---------------------------------------------------------------------
-- REWARD HANDLERS
---------------------------------------------------------------------

local function grantReward(hand, player, rng)
    if hand.name == "PAIR" then
        addPermanentBonus(player, "tears", 1)
        return true

    elseif hand.name == "TWO PAIR" then
        addPermanentBonus(player, "damage", 1)
        return true

    elseif hand.name == "THREE OF A KIND" then
        addPermanentBonus(player, "luck", 1)
        return true

    elseif hand.name == "FLUSH" then
        return spawnBreakfast(player)

    elseif hand.name == "FULL HOUSE" then
        return duplicateRemainingEligible(hand, player)

    elseif hand.name == "FOUR OF A KIND" then
        return spawnPoolItems(
            player,
            ItemPoolType.POOL_TREASURE,
            3,
            rng,
            1
        )

    elseif hand.name == "FIVE OF A KIND" then
        return spawnPoolItems(
            player,
            ItemPoolType.POOL_SECRET,
            2,
            rng,
            2
        )

    elseif hand.name == "ARCANA RUN" then
        local devilShare, angelShare = getDevilAngelShares()
        local poolType

        if rng:RandomFloat() < angelShare then
            poolType = ItemPoolType.POOL_ANGEL
        else
            poolType = ItemPoolType.POOL_DEVIL
        end

        return spawnPoolItems(player, poolType, 2, rng, nil)

    elseif hand.name == "ROYAL FLUSH" then
        local angelSuccess = spawnPoolItems(
            player,
            ItemPoolType.POOL_ANGEL,
            2,
            rng,
            3
        )

        if not angelSuccess then
            return false
        end

        return spawnPoolItems(
            player,
            ItemPoolType.POOL_DEVIL,
            2,
            rng,
            4
        )
    end

    return false
end

---------------------------------------------------------------------
-- ITEM ACTIVATION
---------------------------------------------------------------------

function mod:OnUseItem(item, rng, player, useFlags, activeSlot, varData)
    local hand = getBestHand(collectEligible())

    if not hand then
        log("Activation: no valid hand.")
        return {
            Discharge = false,
            Remove = false,
            ShowAnim = false,
        }
    end

    log("Selected hand: " .. hand.name)

    -- Grant the reward immediately
    if not grantReward(hand, player, rng) then
        log("Reward could not be created. Pickups left untouched.")

        return {
            Discharge = false,
            Remove = false,
            ShowAnim = false,
        }
    end

    -- Remove the consumed physical cards/pills immediately
    for _, entry in ipairs(hand.selected) do
        if entry.pickup and entry.pickup:Exists() then
            entry.pickup:Remove()
        end
    end

    log("Played " .. hand.name)

    return {
        Discharge = true,
        Remove = false,
        ShowAnim = true,
    }
end

mod:AddCallback(
    ModCallbacks.MC_USE_ITEM,
    mod.OnUseItem,
    mod.COLLECTIBLE_ONE_LAST_HAND
)
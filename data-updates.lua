-- Fix: SeaBlock sb-startup1 references recipes that no longer exist
-- ('angels-ore1-crushed-smelting', 'angels-ore3-crushed-smelting').
-- Remove any unlock-recipe effects whose recipe is not defined.

local tech = data.raw["technology"]["sb-startup1"]
if tech and tech.effects then
    local fixed = {}
    for _, effect in ipairs(tech.effects) do
        if effect.type ~= "unlock-recipe" or data.raw["recipe"][effect.recipe] then
            table.insert(fixed, effect)
        end
    end
    tech.effects = fixed
end

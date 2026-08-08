--!strict

-- Static catalog of the Robux store (PlayerGui.ScreenGui.ShopUI, driven by the client's
-- ShopUiController and granted by the server's ShopProductsService), keyed by the NAME of the
-- ScrollingFrame ImageLabel each offer is authored as. Shared so the client's "is this still worth
-- selling?" check and the server's grant can't disagree on what an offer hands over.
--
-- TWO KINDS OF PURCHASE
--
-- Most offers are DEVELOPER PRODUCTS -- bought repeatedly, delivered by a receipt. The permanent
-- perks (2x Cash / 2x Gems, the starter pack) are GAMEPASSES instead: bought once and OWNED
-- forever, with no receipt at all. The two need completely different plumbing, so each offer's
-- product id is listed in exactly one of DevProductFallbacks or GamePasses, and that membership is
-- what tells the client which prompt to raise and the server how to deliver it.
--
-- SEVERAL OFFERS SHARE A PRODUCT ID
--
-- The cash/gem pairs are sold through the same developer product (25k cash + 25k gems are both
-- 3644862015, and so on), so the product id alone cannot say what to grant. For DEV PRODUCTS the
-- click is what decides: the client fires the frame name over the ShopIntent remote just before
-- prompting, the server remembers it, and the receipt grants whatever was last reached for. Same
-- mechanism ShopService uses for its shortfall product.
--
-- An intent belongs to one session, so a receipt delivered after a restart can arrive with none
-- recorded. DevProductFallbacks names the offer to grant in that case -- one per product id, so a
-- lost intent still hands over something reasonable rather than swallowing the purchase. For the
-- products with a single offer (speed) the fallback IS that offer, so those can never mis-grant.
--
-- A GAMEPASS can't work that way: ownership is one permanent boolean, so a player who bought the
-- pass through one frame would never be able to prompt it again from the other, and an intent
-- recorded a session ago is long gone by the time we re-check ownership on their next join. So a
-- gamepass grants the UNION of every offer sold on it (see offersFor) -- owning the pass means
-- owning everything the store sells under it. Two frames on one pass are therefore two shop-fronts
-- for the same purchase; give them separate pass ids to make them separately buyable.
--
-- SkillsPackFrame is deliberately absent from BOTH lists: its product is the SkillsDisplay's
-- "unlock all skills" dev product, already owned by SkillsService's receipt handler (only one
-- handler may exist per product). The shop just prompts it; SkillsService grants it.

local ShopProducts = {}

-- One store offer. Every field past `productId` is an optional part of the grant, so an offer is
-- just the set of things it hands over:
--   * cash / gems       -- flat currency, credited raw (NOT scaled by Greed/Hoarding or by the
--                          multipliers below -- a 100k pack pays exactly 100k).
--   * cashMultiplier /
--     gemMultiplier     -- PERMANENT multiplier on all future cash/gem earnings (see ShopPerks).
--   * speedBonus        -- PERMANENT studs/sec added to walk speed, free-roam and on the job alike.
--   * starterPack       -- unlock every tool and max each one's upgrade level.
--   * skills            -- max every skill. Granted by SkillsService, not ShopProductsService.
export type Offer = {
	productId: number,
	cash: number?,
	gems: number?,
	cashMultiplier: number?,
	gemMultiplier: number?,
	speedBonus: number?,
	starterPack: boolean?,
	skills: boolean?,
}

-- Every offer, keyed by its ScrollingFrame ImageLabel name.
ShopProducts.Offers = {
	["25kCashFrame"] = { productId = 3644862015, cash = 25000 },
	["25kGemsFrame"] = { productId = 3644862015, gems = 25000 },
	["100kCashFrame"] = { productId = 3644878823, cash = 100000 },
	["100kGemsFrame"] = { productId = 3644878823, gems = 100000 },
	-- Both 2x frames currently sell the SAME gamepass ("2xCash", 1941048632), so owning it grants
	-- both multipliers -- see the header. Point 2xGemsFrame at its own pass id to split them.
	["2xCashFrame"] = { productId = 1941048632, cashMultiplier = 2 },
	["2xGemsFrame"] = { productId = 1941048632, gemMultiplier = 2 },
	["SpeedFrame"] = { productId = 3644904933, speedBonus = 12 },
	["StarterPackFrame"] = { productId = 1943706546, starterPack = true },
	["SkillsPackFrame"] = { productId = 3609731896, skills = true },
} :: { [string]: Offer }

-- DEVELOPER PRODUCTS: which offer a product id grants when no intent was recorded (see the
-- header). Doubles as the list of dev products ShopProductsService registers a receipt handler
-- for -- the skills product is absent because SkillsService owns that one.
ShopProducts.DevProductFallbacks = {
	[3644862015] = "25kCashFrame",
	[3644878823] = "100kCashFrame",
	[3644904933] = "SpeedFrame",
} :: { [number]: string }

-- GAMEPASSES: bought once and owned forever. Owning one grants every offer sold on it (offersFor),
-- both when the purchase completes and on each later join, so ownership and perks can't drift apart.
ShopProducts.GamePasses = {
	[1941048632] = true, -- "2xCash" -- currently backs 2xCashFrame AND 2xGemsFrame
	[1943706546] = true, -- "Starter Pack"
} :: { [number]: boolean }

-- The offer authored on the frame named `frameName`, or nil if that frame sells nothing.
function ShopProducts.get(frameName: string): Offer?
	return ShopProducts.Offers[frameName]
end

-- Whether `productId` is bought as a gamepass rather than a developer product. Decides which
-- prompt the client raises and which delivery path the server uses.
function ShopProducts.isGamePass(productId: number): boolean
	return ShopProducts.GamePasses[productId] == true
end

-- Every offer sold on `productId`. Usually one; more when several frames share an id. Gamepass
-- delivery grants all of them (see the header), so this is the union owning that pass is worth.
function ShopProducts.offersFor(productId: number): { Offer }
	local matches: { Offer } = {}
	for _, offer in ShopProducts.Offers do
		if offer.productId == productId then
			table.insert(matches, offer)
		end
	end
	return matches
end

return ShopProducts

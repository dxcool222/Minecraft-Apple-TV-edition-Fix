#import "MCFIXEntitlementCatalog.h"

// tvOS 1.1.5 expanded marketplace registry (sub_10049D490 + STORE_PURCHASE_UNLOCK_AUDIT.md).
const MCFIXEntitlementCatalogEntry kMCFIXProductionEntitlementCatalog[] = {
    { "texturepack.steampunk", "db79d265-2285-4646-916a-73228c727be9", "Steampunk Texture Pack",
      "resource_packs" },
    { "texturepack.purebdcraft", "1ece5830-0b47-4511-8b67-04df547a4d9e", "PureBDcraft Texture Pack",
      "resource_packs" },
    { "skin.survivors", "d637ef26-1c09-42a1-8ad4-e7316325ddc0", "Survivors Skin Pack", "skin_packs" },
    { "skin.kingsandpaupers", "b9cd3646-0da8-4e09-a239-e2594a0673d8", "Kings and Paupers Skin Pack",
      "skin_packs" },
    { "skin.sports", "8d1cce17-c707-4ae5-bf45-989e49e9b504", "Sports Skin Pack", "skin_packs" },
    { "skin.summerfestival", "9ed86ce1-4f5e-4f23-a8c5-ae6b7ae4dc5c", "Summer Festival Skin Pack",
      "skin_packs" },
    { "world.infinitydungeonex", "ca3bca92-6c18-4a09-8d39-1c911d766e74", "Infinity Dungeon EX",
      "behavior_packs" },
    { "world.thecrater", "bbfcfdc8-83b9-4534-9daa-0ba9aa5bb42f", "The Crater", "behavior_packs" },
    { "world.strandedsub", "f7c5dd73-227a-4d19-a6e8-9f7bfb87b8a1", "Stranded SUB", "behavior_packs" },
    { "world.monsterbattlearena", "abb8b284-a5f0-48b1-a1a0-9444cc541c78", "Monster Battle Arena",
      "behavior_packs" },
    { "world.dinosaurisland", "094c02f5-bd87-4588-acd3-8fab523f3293", "Dinosaur Island",
      "behavior_packs" },
    { "world.lapislagoon", "b4f0298e-0dc0-45e4-9569-9acd62792082", "Lapis Lagoon", "behavior_packs" },
    { "world.islesofaeria", "ed7234b2-4f29-46cd-a45f-2f2e04d76f32", "Isles of Aeria",
      "behavior_packs" },
    { "world.abstractionvector", "6775305f-1533-4243-8ab0-3eb4285e26f2", "Abstraction Vector",
      "behavior_packs" },
    { "world.ninjasvssamurai", "79a31aea-1f7e-4e31-b83d-d12199bca9f6", "Ninjas vs Samurai",
      "behavior_packs" },
    { "world.whiterockcastle", "d02f7fcf-1d59-40c1-a2d3-7c98d53d9d27", "Whiterock Castle",
      "behavior_packs" },
};

const size_t kMCFIXProductionEntitlementCatalogCount =
    sizeof(kMCFIXProductionEntitlementCatalog) / sizeof(kMCFIXProductionEntitlementCatalog[0]);

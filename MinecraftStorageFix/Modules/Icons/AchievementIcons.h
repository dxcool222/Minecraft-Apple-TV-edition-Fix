#pragma once

#import <Foundation/Foundation.h>
#import <stdio.h>

// One-time copy of bundle achievement chrome PNGs into
// $HOME/tmp/minecraftpe/AchievementIcons. Hashed (Xbox-issued) PNGs are
// produced by Xbox Live at runtime — bundle seeding only covers the
// vanilla UI chrome assets so the achievements screen has placeholders.
void MCFIXSeedAchievementIconsFromBundle(void);

// Bi-directional copy between the container path the game opens and the
// VFS-mirrored path so reads from either resolve to the same content.
NSUInteger MCFIXSyncAchievementIconsBidirectional(void);

// Diagnostic logging for the achievement-icon code path.
void MCFIXLogAchievementIconBootProbe(void);
void MCFIXLogAchievementAccessProbe(const char *resolvedPath, int accessRc);
void MCFIXLogAchievementFopenProbe(const char *path, const char *mode, FILE *result);

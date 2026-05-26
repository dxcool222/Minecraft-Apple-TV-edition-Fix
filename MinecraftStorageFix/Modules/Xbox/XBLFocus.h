#pragma once

#import <Foundation/Foundation.h>

// Auto-complete Xbox sign-in on tvOS welcome screen (formerly
// XBLFocusFix.framework). The welcome page doesn't fully wire the
// focused-element callbacks under tvOS sideload — overriding
// -[XBLTVWelcomePageViewController showLogInState] lets us call the
// delegate's userCompletedSignedIn directly so the flow advances.
void MCFIXInstallXBLFocusFix(void);

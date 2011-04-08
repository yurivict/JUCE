/*
  ==============================================================================

   This file is part of the JUCE library - "Jules' Utility Class Extensions"
   Copyright 2004-11 by Raw Material Software Ltd.

  ------------------------------------------------------------------------------

   JUCE can be redistributed and/or modified under the terms of the GNU General
   Public License (Version 2), as published by the Free Software Foundation.
   A copy of the license is included in the JUCE distribution, or can be found
   online at www.gnu.org/licenses.

   JUCE is distributed in the hope that it will be useful, but WITHOUT ANY
   WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
   A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

  ------------------------------------------------------------------------------

   To release a closed-source product which uses JUCE, commercial licenses are
   available: visit www.rawmaterialsoftware.com/juce for more information.

  ==============================================================================
*/

//==============================================================================
#include "../juce_IncludeCharacteristics.h"

#if JucePlugin_Build_VST

#include <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>

#define JUCE_MAC_WINDOW_VISIBITY_BODGE 1

#include "../juce_PluginHeaders.h"
#include "../juce_PluginHostType.h"

#if ! (JUCE_64BIT || defined (ADD_CARBON_BODGE))
 #define ADD_CARBON_BODGE 1   // see note below..
#endif

//==============================================================================
BEGIN_JUCE_NAMESPACE

static void updateComponentPos (Component* const comp)
{
    HIViewRef dummyView = (HIViewRef) (void*) (pointer_sized_int)
                            comp->getProperties() ["dummyViewRef"].toString().getHexValue64();

    HIRect r;
    HIViewGetFrame (dummyView, &r);
    HIViewRef root;
    HIViewFindByID (HIViewGetRoot (HIViewGetWindow (dummyView)), kHIViewWindowContentID, &root);
    HIViewConvertRect (&r, HIViewGetSuperview (dummyView), root);

    Rect windowPos;
    GetWindowBounds (HIViewGetWindow (dummyView), kWindowContentRgn, &windowPos);

    comp->setTopLeftPosition ((int) (windowPos.left + r.origin.x),
                              (int) (windowPos.top + r.origin.y));
}

static pascal OSStatus viewBoundsChangedEvent (EventHandlerCallRef, EventRef, void* user)
{
    updateComponentPos ((Component*) user);
    return noErr;
}

//==============================================================================
void initialiseMac()
{
   #if ! JUCE_64BIT
    NSApplicationLoad();
   #endif
}

void* attachComponentToWindowRef (Component* comp, void* windowRef)
{
    JUCE_AUTORELEASEPOOL

  #if JUCE_64BIT
    NSView* parentView = (NSView*) windowRef;

   #if JucePlugin_EditorRequiresKeyboardFocus
    comp->addToDesktop (0, parentView);
   #else
    comp->addToDesktop (ComponentPeer::windowIgnoresKeyPresses, parentView);
   #endif

    [[parentView window] setAcceptsMouseMovedEvents: YES];
    return parentView;
  #else
    NSWindow* hostWindow = [[NSWindow alloc] initWithWindowRef: windowRef];
    [hostWindow retain];
    [hostWindow setCanHide: YES];
    [hostWindow setReleasedWhenClosed: YES];

    HIViewRef parentView = 0;

    WindowAttributes attributes;
    GetWindowAttributes ((WindowRef) windowRef, &attributes);
    if ((attributes & kWindowCompositingAttribute) != 0)
    {
        HIViewRef root = HIViewGetRoot ((WindowRef) windowRef);
        HIViewFindByID (root, kHIViewWindowContentID, &parentView);

        if (parentView == 0)
            parentView = root;
    }
    else
    {
        GetRootControl ((WindowRef) windowRef, (ControlRef*) &parentView);

        if (parentView == 0)
            CreateRootControl ((WindowRef) windowRef, (ControlRef*) &parentView);
    }

    // It seems that the only way to successfully position our overlaid window is by putting a dummy
    // HIView into the host's carbon window, and then catching events to see when it gets repositioned
    HIViewRef dummyView = 0;
    HIImageViewCreate (0, &dummyView);
    HIRect r = { {0, 0}, {comp->getWidth(), comp->getHeight()} };
    HIViewSetFrame (dummyView, &r);
    HIViewAddSubview (parentView, dummyView);
    comp->getProperties().set ("dummyViewRef", String::toHexString ((pointer_sized_int) (void*) dummyView));

    EventHandlerRef ref;
    const EventTypeSpec kControlBoundsChangedEvent = { kEventClassControl, kEventControlBoundsChanged };
    InstallEventHandler (GetControlEventTarget (dummyView), NewEventHandlerUPP (viewBoundsChangedEvent), 1, &kControlBoundsChangedEvent, (void*) comp, &ref);
    comp->getProperties().set ("boundsEventRef", String::toHexString ((pointer_sized_int) (void*) ref));

    updateComponentPos (comp);

   #if ! JucePlugin_EditorRequiresKeyboardFocus
    comp->addToDesktop (ComponentPeer::windowIsTemporary | ComponentPeer::windowIgnoresKeyPresses);
   #else
    comp->addToDesktop (ComponentPeer::windowIsTemporary);
   #endif

    comp->setVisible (true);
    comp->toFront (false);

    NSView* pluginView = (NSView*) comp->getWindowHandle();
    NSWindow* pluginWindow = [pluginView window];
    [pluginWindow setExcludedFromWindowsMenu: YES];
    [pluginWindow setCanHide: YES];

    [hostWindow addChildWindow: pluginWindow
                       ordered: NSWindowAbove];
    [hostWindow orderFront: nil];
    [pluginWindow orderFront: nil];

    attachWindowHidingHooks (comp, (WindowRef) windowRef, hostWindow);

    return hostWindow;
  #endif
}

void detachComponentFromWindowRef (Component* comp, void* nsWindow)
{
   #if JUCE_64BIT
    comp->removeFromDesktop();
   #else
    {
        JUCE_AUTORELEASEPOOL

        EventHandlerRef ref = (EventHandlerRef) (void*) (pointer_sized_int)
                                    comp->getProperties() ["boundsEventRef"].toString().getHexValue64();
        RemoveEventHandler (ref);

        removeWindowHidingHooks (comp);

        HIViewRef dummyView = (HIViewRef) (void*) (pointer_sized_int)
                                comp->getProperties() ["dummyViewRef"].toString().getHexValue64();

        if (HIViewIsValid (dummyView))
            CFRelease (dummyView);

        NSWindow* hostWindow = (NSWindow*) nsWindow;
        NSView* pluginView = (NSView*) comp->getWindowHandle();
        NSWindow* pluginWindow = [pluginView window];

        [hostWindow removeChildWindow: pluginWindow];
        comp->removeFromDesktop();

        [hostWindow release];
    }

    // The event loop needs to be run between closing the window and deleting the plugin,
    // presumably to let the cocoa objects get tidied up. Leaving out this line causes crashes
    // in Live and Reaper when you delete the plugin with its window open.
    // (Doing it this way rather than using a single longer timout means that we can guarantee
    // how many messages will be dispatched, which seems to be vital in Reaper)
    for (int i = 20; --i >= 0;)
        MessageManager::getInstance()->runDispatchLoopUntil (1);
   #endif
}

void setNativeHostWindowSize (void* nsWindow, Component* component, int newWidth, int newHeight, const PluginHostType& host)
{
    JUCE_AUTORELEASEPOOL

   #if JUCE_64BIT
    NSView* hostView = (NSView*) nsWindow;
    if (hostView != 0)
    {
        // xxx is this necessary, or do the hosts detect a change in the child view and do this automatically?
        [hostView setFrameSize: NSMakeSize ([hostView frame].size.width + (newWidth - component->getWidth()),
                                            [hostView frame].size.height + (newHeight - component->getHeight()))];
    }
   #else
    NSWindow* hostWindow = (NSWindow*) nsWindow;
    if (hostWindow != 0)
    {
        // Can't use the cocoa NSWindow resizing code, or it messes up in Live.
        Rect r;
        GetWindowBounds ((WindowRef) [hostWindow windowRef], kWindowContentRgn, &r);
        r.right += newWidth - component->getWidth();
        r.bottom += newHeight - component->getHeight();
        SetWindowBounds ((WindowRef) [hostWindow windowRef], kWindowContentRgn, &r);

        r.left = r.top = 0;
        InvalWindowRect ((WindowRef) [hostWindow windowRef], &r);
    }
   #endif
}

void checkWindowVisibility (void* nsWindow, Component* comp)
{
   #if ! JUCE_64BIT
    comp->setVisible ([((NSWindow*) nsWindow) isVisible]);
   #endif
}

void forwardCurrentKeyEventToHost (Component* comp)
{
   #if ! JUCE_64BIT
    NSWindow* win = [(NSView*) comp->getWindowHandle() window];
    [[win parentWindow] makeKeyWindow];
    [NSApp postEvent: [NSApp currentEvent] atStart: YES];
   #endif
}


END_JUCE_NAMESPACE

#endif

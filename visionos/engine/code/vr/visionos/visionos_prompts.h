// Controller wording for the prompts the PC game data spells out as keys ("USE [W,S,A,D] TO MOVE
// AROUND", "[LEFT-CLICK] TO GET INTO CAR"). visionOS is played with controllers, and the PC text
// bible has console variants for only a couple of these.
#ifndef SHAR_VISIONOS_PROMPTS_H
#define SHAR_VISIONOS_PROMPTS_H

namespace SharVisionOS
{
    // The TUTORIAL_%03d entry reworded for the controller layout in use: VR mode's (upstream's
    // Quest layout) or Original mode's (the console layout). nullptr where the PC text names no keys.
    const char* ControllerTutorialText(int index, bool vrMode);

    // The label shown in place of the PC's [F1] next to "Disable Tutorials" (the X button).
    const char* DisableTutorialsText();
}

#endif

/* Actual guest + shared renderer, with no Activity/OpenXR session. Built only
 * by the explicit offscreen diagnostic option; never installed as an app. */
#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <stdlib.h>
#include <stdio.h>
extern int game_main(int argc,char **argv);
int main(int argc,char **argv)
{
    setvbuf(stdout,NULL,_IOLBF,0);setvbuf(stderr,NULL,_IOLBF,0);
    SDL_SetMainReady();
    setenv("SDL_VIDEODRIVER","dummy",1);
    setenv("SDL_AUDIODRIVER","dummy",1);
    return game_main(argc,argv);
}

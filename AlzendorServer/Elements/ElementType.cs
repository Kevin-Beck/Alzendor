using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer.Elements
{
    public enum ElementType
    {
        MESSAGE, // A bundle of text sent to a channel to be read by others
        CHANNEL, // the places where communication occurs, DMs and General chat etc 
        USER, // the actual person who has conencted to the game
        PLAYER, // any player character
        NPC, // any non player character, enemies, quest givers
        ITEM, // weapons, clothing, etc in game
        ROOM, // the group of tiles that can be navigated around
        SPACE, // the tile upon which a person stands
        HELP // Info about the game itself (how commands work etc)
    }
}

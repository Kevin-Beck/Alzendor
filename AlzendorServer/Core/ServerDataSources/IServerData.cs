using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public interface IServerData
    {
        public GameState LoadGameState();
        public void SaveGameState(GameState state);
    }
}

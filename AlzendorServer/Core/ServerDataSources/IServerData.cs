using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public interface IServerData
    {
        public string LoadGameState();
        public void SaveGameState(string state);
    }
}

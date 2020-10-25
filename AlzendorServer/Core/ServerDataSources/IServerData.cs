using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer
{
    public interface IServerData
    {
        public string LoadGameState();
        public void SaveGameState(string state);
    }
}

using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public class GameState
    {
        List<ServerObject> objects = new List<ServerObject>();
        public void AddObjectToGameState(ServerObject serverObject)
        {
            objects.Add(serverObject);
        }
        public List<ServerObject> GetServerObjectList()
        {
            return objects;
        }
    }
}

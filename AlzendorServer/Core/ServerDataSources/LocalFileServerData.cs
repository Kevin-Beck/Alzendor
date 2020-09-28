using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Alzendor.Server.DataSources
{
    class LocalFileServerData : IServerData
    {
        public GameState LoadGameState()
        {
            string path = Directory.GetCurrentDirectory() + "\\ServerData";
            GameState gameState = new GameState();
            try
            {
                using (StreamReader streamReader = File.OpenText(path))
                {
                    string serializedObject = "";

                    while ((serializedObject = streamReader.ReadLine()) != null)
                    {
                        gameState.AddObjectToGameState(JsonConvert.DeserializeObject<ServerObject>(serializedObject));
                    }
                }
            }catch(Exception e)
            {
                Console.WriteLine(e.StackTrace);
            }

            return gameState;
        }

        public void SaveGameState(GameState state)
        {
            string path = Directory.GetCurrentDirectory() + "\\ServerData";
            GameState gameState = new GameState();

            using (StreamWriter streamWriter = new StreamWriter(path))
            {                
                foreach(ServerObject serverObject in gameState.GetServerObjectList())
                {
                    streamWriter.WriteLine(JsonConvert.SerializeObject(serverObject));
                }
            }
        }
    }
}

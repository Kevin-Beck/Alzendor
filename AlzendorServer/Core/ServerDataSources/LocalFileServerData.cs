using AlzendorServer.Core.Elements;
using Newtonsoft.Json;
using System;
using System.IO;

namespace AlzendorServer.DataSources
{
    class LocalFileServerData : IServerData
    {
        public string LoadGameState()
        {
            string path = Directory.GetCurrentDirectory() + "\\ServerData";
            string gameState = "";
            try
            {
                using StreamReader streamReader = File.OpenText(path);
                string serializedObject = "";

                while ((serializedObject = streamReader.ReadLine()) != null)
                {
                    gameState += (JsonConvert.DeserializeObject<GameElement>(serializedObject));
                }
            }
            catch(FileNotFoundException e)
            {
                
                Console.WriteLine("No local saved gamestate found, starting from scratch " + e.ToString());
            }catch(Exception other)
            {
                Console.WriteLine("ServerError: " + other.Message);
            }

            return gameState;
        }

        public void SaveGameState(string state)
        {
            string path = Directory.GetCurrentDirectory() + "\\ServerData";
            string gameState = "";

            using StreamWriter streamWriter = new StreamWriter(path);
            streamWriter.WriteLine(gameState);
        }
    }
}

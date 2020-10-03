﻿using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Alzendor.Server.DataSources
{
    class LocalFileServerData : IServerData
    {
        public string LoadGameState()
        {
            string path = Directory.GetCurrentDirectory() + "\\ServerData";
            string gameState = "";
            try
            {
                using (StreamReader streamReader = File.OpenText(path))
                {
                    string serializedObject = "";

                    while ((serializedObject = streamReader.ReadLine()) != null)
                    {
                        gameState += (JsonConvert.DeserializeObject<ServerObject>(serializedObject));
                    }
                }
            }catch(FileNotFoundException e)
            {
                Console.WriteLine("No local saved gamestate found, starting from scratch");
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

            using (StreamWriter streamWriter = new StreamWriter(path))
            {    
                streamWriter.WriteLine(gameState);
            
            }
        }
    }
}
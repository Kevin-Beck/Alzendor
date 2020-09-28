using Alzendor.Core.Utilities.DataTransfer;
using Alzendor.Core.Utilities.Logger;
using System;

namespace Alzendor.Client
{
    public class ClientMain
    {
        public static int Main(String[] args)
        {
            ILogger logger = new LocalFileLogger();
            StartClient(logger);
            return 0;
        }
        public static void StartClient(ILogger logger)
        {
            Console.Write("Enter your name: ");
            var characterName = Console.ReadLine();
            ConnectionToServer serverConnection = new ConnectionToServer(logger, characterName, "localhost", 11000, 1024, 100);
            UserInputInterpretter inputManager = new UserInputInterpretter();

            while (true)
            {
                var userInput = Console.ReadLine();
                var action = inputManager.ParseActionFromText(characterName, userInput);
                if (action != null)
                {
                    serverConnection.SendAction(action);
                }
            }
        }       
    }
}
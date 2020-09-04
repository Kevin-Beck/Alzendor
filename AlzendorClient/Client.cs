using System;
using AlzendorCore.Utilities.Logger;
using System.Threading;
using AlzendorCore.Utilities.DataTransfer;

namespace AlzendorClient
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
            ConnectionToServer serverConnection = new ConnectionToServer(logger, "localhost", 1024, 100);
            UserInputInterpretter inputManager = new UserInputInterpretter();

            while (true)
            {
                var userInput = Console.ReadLine();
                var action = inputManager.ParseActionFromText("Morek", userInput);
                if (action != null)
                {
                    serverConnection.SendAction(action);
                }
            }
        }       
    }
}
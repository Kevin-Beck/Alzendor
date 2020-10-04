using Alzendor.Core.Utilities.Logger;
using System;

namespace Alzendor.Client
{
    public class CommandLineClient
    {
        public static int Main(String[] args)
        {
            ILogger logger = new LocalFileLogger();
            ConnectionToServer serverConnection;
            string serverIP ="localhost";
            string myIP = "localhost";
            int serverPort = 11000;

            // Create the Client
            CommandLineClient clientMain = new CommandLineClient(logger, serverIP, myIP, serverPort);
            return 0;
        }


        private readonly ILogger logger;
        private readonly string serverIP;
        private readonly int serverPort;

        public CommandLineClient(ILogger log, string serverip, string myIP, int port)
        {
            logger = log;
            serverIP = serverip;
            serverPort = port;

            string charname = GetLoginInformation();
            StartClientIO(charname);
        }
        private string GetLoginInformation()
        { 
            Console.Write("Enter your username: ");
            return Console.ReadLine();       
        }
        private void StartClientIO(string name)
        {
            ConnectionToServer serverConnection = new ConnectionToServer(logger, name, serverIP, serverPort);

            while (true)
            {
                serverConnection.DataToSend = Console.ReadLine();
            }
        }       
    }
}
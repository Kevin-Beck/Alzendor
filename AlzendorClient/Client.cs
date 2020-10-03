using Alzendor.Core.Utilities.Logger;
using System;
using System.Net;
using System.Threading;

namespace Alzendor.Client
{
    public class CommandLineClient
    {
        public static int Main(String[] args)
        {
            ILogger logger = new LocalFileLogger();
            string serverIP ="localhost";
            string myIP = "localhost";
            int serverPort = 11000;

            // Create the Client
            CommandLineClient clientMain = new CommandLineClient(logger, serverIP, myIP, serverPort);
            return 0;
        }

        // TODO add debug/info logging
        private ILogger logger;
        private string serverIP;
        private string myIP;
        private int serverPort;

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
            ConnectionToServer serverConnection = new ConnectionToServer(logger, name, serverIP, myIP, serverPort);


            for(int i = 0; i < 10; i++)
            {
                Thread.Sleep(5000);
                serverConnection.DataToSend = $"Client Msg ({i})";
            }
        }       
    }
}
using log4net;
using log4net.Config;
using System;
using System.IO;
using System.Reflection;
using System.Threading;

namespace Alzendor.Client
{
    public class CommandLineClient
    {
        private static readonly ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);

        public static int Main(String[] args)
        {
            // configure logger
            var logRepository = LogManager.GetRepository(Assembly.GetEntryAssembly());
            XmlConfigurator.Configure(logRepository, new FileInfo("log4net.config"));

            // determine target ip for server
            string serverIP = args.Length > 0 ? args[0] : "localhost";

            // configure port
            int serverPort = 11000;
            logger.Info($"Client looking for: {serverIP} + {serverPort}");
            // Create the Client
            CommandLineClient clientMain = new CommandLineClient(logger, serverIP, serverPort);
            return 0;
        }

        private readonly string serverIP;
        private readonly int serverPort;
        ConnectionToServer connection;
        private bool loggedIn = false;

        public CommandLineClient(ILog log, string serverip, int port)
        {
            serverIP = serverip;
            serverPort = port;
            CreateConnection();
            LogIn();
            
            while (true)
            {
                connection.Send(Console.ReadLine());
            }
        }        
        private void CreateConnection()
        {
            connection = new ConnectionToServer(logger, serverIP, serverPort);
            Thread receiveThread = new Thread(Receive);
            receiveThread.Start();
        }
        public void Receive()
        {
            while(true)
            {
                var dataFromServer = connection.Receive(); // Receive prints it out in the connection fyi            
            }
        }
        private void LogIn()
        {
            while (!loggedIn)
            {

                connection.Send(Console.ReadLine());
            }
        }
    }
}
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
                var dataFromServer = connection.Receive();
                //logger.Info(dataFromServer);
            }
        }
        private void LogIn()
        {
            // todo create the protocol for logging in (the back and forth auth system
            // probably do something like the following: (or just use a library of some kind
            // 1 username is not on the server, reply with "Create new character?"
            // client sends yes, server generates a random salt and sends random salt to user
            // client enters password and salts it, they send this salted password to server.
            // server stores client's name, clients randomly generated salt, and clients salted password
            // client is logged in

            // in the future, when client requests to connect to the game server sends back the stored rng salt
            // client types in password which gets salted with the rng salt and then a returned value is sent back
            // server verifies that the sent salted password matches the salted password int he data base
            Console.Write("Enter your username: ");
            connection.Send(Console.ReadLine());
        }
    }
}
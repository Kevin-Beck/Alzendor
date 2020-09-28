using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using Alzendor.Core.Utilities.Logger;
using Alzendor.Server.DataSources;

namespace Alzendor.Server
{
    public class ServerMain
    {        
        public static int Main(String[] args)
        {
            ILogger logger = new LocalFileLogger();
            IServerData serverData = new LocalFileServerData();
            GameState currentGameState = serverData.LoadGameState();
            StartServer(logger, currentGameState);
            return 0;
        }

        public static void StartServer(ILogger logger, GameState gameState)
        {
            bool localBuild = true;
            IPHostEntry host;
            if (localBuild)
            {
                host = Dns.GetHostEntry("localhost");
            }
            else
            {
                host = Dns.GetHostEntry("ec2-3-133-100-129.us-east-2.compute.amazonaws.com");
            }
            IPAddress ipAddress = host.AddressList[0];
            IPEndPoint localEndPoint = new IPEndPoint(ipAddress, 11000);

            try
            {
                List<KeyValuePair<string, ClientConnection>> myConnections;

                // Create a Socket that will use Tcp protocol      
                Socket listener = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                // A Socket must be associated with an endpoint using the Bind method  
                listener.Bind(localEndPoint);
                // Specify how many requests a Socket can listen before it gives Server busy response.  
                // We will listen 10 requests at a time  
                listener.Listen(10);

                Socket incomingClient;
                int clientCounter = 0;

                while (true)
                {
                    logger.Log(LogLevel.Info, "Waiting for a connection...");
                    incomingClient = listener.Accept();
                    clientCounter++;

                    ClientConnection client = new ClientConnection(logger, gameState);
                    // build out list of connections to keep track, set subscribers
                    
                    client.StartClient(incomingClient, clientCounter.ToString());
                }
            }
            catch (Exception e)
            {
                logger.Log(LogLevel.Error, e.ToString());
            }

            logger.Log(LogLevel.Info, "Press any key to continue...");
        }
    }
}

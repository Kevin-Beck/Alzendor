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
            StartServer(logger, "localhost");
            return 0;
        }


        static Dictionary<string, ConnectionToClient> myConnections = new Dictionary<string, ConnectionToClient>();
        public static void StartServer(ILogger logger, string hostURL)
        {
            try
            {
                // todo unhardcode the ports 11000
                IPHostEntry host = Dns.GetHostEntry(hostURL);
                IPAddress ipAddress = host.AddressList[0];
                IPEndPoint localEndPoint = new IPEndPoint(ipAddress, 11000);

                Socket listener = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                listener.Bind(localEndPoint); 
                listener.Listen(10);

                Socket incomingClient;

                while (true)
                {
                    logger.Log(LogLevel.Info, "Waiting for a connection...");
                    incomingClient = listener.Accept();
                    
                    ConnectionToClient client = new ConnectionToClient(logger);
                    client.StartClient(incomingClient);

                    myConnections.Add(client.receiveFromClientSocket.RemoteEndPoint.ToString(), client);
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

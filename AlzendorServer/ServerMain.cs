using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using Alzendor.Server.Core.Actions;
using Alzendor.Core.Utilities.DataTransfer;
using Alzendor.Core.Utilities.Logger;
using Alzendor.Server.DataSources;
using Alzendor.Server.Core.DataTransfer;
using System.Threading;

namespace Alzendor.Server
{
    public class ServerMain
    {
        public static int Main(String[] args)
        {
            Server theServer = new Server();
            RunListenerLoop(theServer);
            return 0;
        }
        public class Server
        {
            public ILogger logger = new LocalFileLogger();
            public string hostURL { get; set; } = "localhost";
            public int port { get; set; }  = 11000;

            public UserInputInterpretter userInputInterpretter;
            readonly List<GameElement> worldElements;
            public Dictionary<string, ConnectionToClient> users;
            public ActionProcessor actionProcessor;
            public Server()
            {
                userInputInterpretter = new UserInputInterpretter();
                worldElements = new List<GameElement>();
                users = new Dictionary<string, ConnectionToClient>();
                actionProcessor = new ActionProcessor(logger, worldElements, users);
                Thread processor = new Thread(ProcessorLoop);
                processor.Start();
            }
            private void ProcessorLoop()
            {
                while (true)
                {
                    actionProcessor.Process();
                }
            }
        }
        public static void RunListenerLoop(Server server)
        {
            try
            {
                IPHostEntry host = Dns.GetHostEntry(server.hostURL);
                IPAddress ipAddress = host.AddressList[0];
                IPEndPoint localEndPoint = new IPEndPoint(ipAddress, server.port);
                Socket listener = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                listener.Bind(localEndPoint); 
                listener.Listen(10);

                Socket incomingClient;

                while (true)
                {                    
                    server.logger.Log(LogLevel.Info, "Waiting for a connection...");
                    incomingClient = listener.Accept();
                    
                    ConnectionToClient client = new ConnectionToClient(server.logger, server.actionProcessor, server.userInputInterpretter);
                    server.logger.Log(LogLevel.Info, "ServerMain received connection.");
                    client.StartClient(incomingClient);
                    server.logger.Log(LogLevel.Info, $"ServerMain created and started connection for: {client.ClientID}");


                    server.logger.Log(LogLevel.Info, $"Adding client: {client.ClientID} to user Dictionary");
                    server.users.Add(client.ClientID, client);


                }
            }
            catch (Exception e)
            {
                server.logger.Log(LogLevel.Error, e.ToString());
            }
            server.logger.Log(LogLevel.Info, "Press any key to continue...");
        }
    }
}

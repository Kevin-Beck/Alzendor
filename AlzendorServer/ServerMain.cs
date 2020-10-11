using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using Alzendor.Server.Core.Actions;
using Alzendor.Server.Core.DataTransfer;
using System.IO;
using System.Reflection;
using log4net;
using log4net.Config;

namespace Alzendor.Server
{
    public class ServerMain
    {
        /// <summary>
        /// Logger is log4net which needs to be configured here an din the log4net.config file at project root.
        /// </summary>
        private static readonly ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        public string HostURL { get; set; }
        public int Port { get; set; } = 11000;
        // TODO fix the server so it resolves its IP without having to be passed it

        public UserInputInterpretter userInputInterpretter; // used by each client connection
        public List<GameElement> worldElements; // list of all world elements
        public Dictionary<string, ConnectionToClient> users; // list of connections to the server
        // this is the users inventory
        public Dictionary<string, ChannelElement> channels; // list of communication channels

        public ActionProcessor actionProcessor;
        public ServerMain(string url)
        {
            HostURL = url;
            userInputInterpretter = new UserInputInterpretter();
            worldElements = new List<GameElement>();
            users = new Dictionary<string, ConnectionToClient>();
            channels = new Dictionary<string, ChannelElement>();

            actionProcessor = new ActionProcessor(logger, this);
        }
        
        public static int Main(String[] args)
        {
            var logRepository = LogManager.GetRepository(Assembly.GetEntryAssembly());
            XmlConfigurator.Configure(logRepository, new FileInfo("log4net.config"));           

            ServerMain theServer = new ServerMain(args.Length > 0 ? args[0] : "localhost");
            RunListenerLoop(theServer);
            return 0;
        }
        public static void RunListenerLoop(ServerMain server)
        {
            try
            {
                logger.Info($"Server operating on: {server.HostURL}");
                IPHostEntry host = Dns.GetHostEntry(server.HostURL);
                IPAddress ipAddress = host.AddressList[0];
                IPEndPoint localEndPoint = new IPEndPoint(ipAddress, server.Port);
                Socket listener = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                listener.Bind(localEndPoint);
                listener.Listen(10);

                Socket incomingClient;

                while (true)
                {
                    logger.Info("Waiting for a connection...");
                    incomingClient = listener.Accept();

                    ConnectionToClient client = new ConnectionToClient(logger, server.actionProcessor, server.userInputInterpretter);
                    logger.Info("ServerMain received connection.");
                    client.StartClient(incomingClient);
                    logger.Info($"ServerMain created and started connection for: {client.ClientID}");


                    logger.Info($"Adding client: {client.ClientID} to user Dictionary");
                    if (server.users.TryGetValue(client.ClientID, out ConnectionToClient connection)){
                        logger.Warn("User already exists");
                    }
                    else
                    {
                        server.users.Add(client.ClientID, client);
                    }

                    if (server.channels.TryGetValue(client.ClientID, out ChannelElement channelElement))
                    {
                        logger.Warn("User channel already exists");
                    }
                    else
                    {
                        logger.Info($"Creating channel for user {client.ClientID} and adding it to channels list");
                        var userChannel = new ChannelElement(client.ClientID, client.ClientID);
                        server.channels.Add(client.ClientID, userChannel);
                        server.actionProcessor.Add(new SubscribeAction(client.ClientID, client.ClientID, SubscriptionType.CHANNEL));                        
                    }
                }
            }
            catch (Exception e)
            {
                logger.Error(e.ToString());
            }
            logger.Info("Press any key to continue...");
        }
    }
}


using System;
using System.Net;
using System.Net.Sockets;
using System.IO;
using System.Reflection;
using log4net;
using log4net.Config;
using StackExchange.Redis;

namespace AlzendorServer.Core
{
    public class ServerMain
    {
        /// <summary>
        /// Logger is log4net which needs to be configured here an din the log4net.config file at project root.
        /// </summary>
        private static readonly ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        public string HostURL { get; set; }
        public int Port { get; set; } = 11000;
        private readonly ConnectionMultiplexer redisMuxor;

        
        public ServerMain(string serverURL = "localhost", string redisURL = "127.0.0.1:6379")
        {
            HostURL = serverURL; // TODO fix the server so it resolves its IP without having to be passed it

            while(redisMuxor == null)
            {
                try
                {
                    logger.Info($"Connecting to redis at {redisURL}");
                    redisMuxor = ConnectionMultiplexer.Connect(redisURL);
                    redisMuxor.GetDatabase().StringSet("admin:LastServerRedisAccess", System.DateTime.Now.ToString());
                }
                catch (Exception e)
                {
                    logger.Error(e.ToString());
                }
            }
            logger.Info("Successfully connected to redis");
        }
        
        public static int Main(String[] args)
        {
            // configure logging
            var logRepository = LogManager.GetRepository(Assembly.GetEntryAssembly());
            XmlConfigurator.Configure(logRepository, new FileInfo("log4net.config"));        

            // kick off the server, if nothing is passed in default to localhost
            ServerMain theServer = new ServerMain();
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
                    try
                    {
                        logger.Info("Waiting for a connection...");
                        incomingClient = listener.Accept();
                        // create a client object for each incoming connection and spin off a new redis connection for each
                        logger.Info("ServerMain received connection.");
                        ConnectionToClient client = new ConnectionToClient(server.redisMuxor.GetDatabase(), server.redisMuxor.GetSubscriber(), incomingClient);
                        logger.Info($"ServerMain created and started connection for: {incomingClient.RemoteEndPoint}");
                    }catch(Exception e)
                    {
                        logger.Info("Caught Exception while listening and creating new connections to clients");
                        logger.Error(e.ToString());
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


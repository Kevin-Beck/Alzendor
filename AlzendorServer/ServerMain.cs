using System;
using System.Net;
using System.Net.Sockets;
using AlzendorCore.Utilities.Logger;

namespace Alzendor.Server
{
    public class ServerMain
    {
        public static int Main(String[] args)
        {
            // Injection of Logger
            ILogger logger = new LocalFileLogger();
            StartServer(logger);
            return 0;
        }

        public static void StartServer(ILogger logger)
        {
            // Get Host IP Address that is used to establish a connection  
            // In this case, we get one IP address of localhost that is IP : 127.0.0.1  
            // If a host has multiple addresses, you will get a list of addresses  

            IPHostEntry host = Dns.GetHostEntry("ec2-3-133-100-129.us-east-2.compute.amazonaws.com");
            IPAddress ipAddress = host.AddressList[0];
            IPEndPoint localEndPoint = new IPEndPoint(ipAddress, 11000);

            try
            {
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

                    ClientConnection client = new ClientConnection(logger);
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

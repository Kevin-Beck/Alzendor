﻿using log4net;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Alzendor.Client
{
    public class ConnectionToServer
    {
        private readonly ILog logger;
        private readonly NetworkStream networkStreamOut;        
        private readonly NetworkStream networkStreamIn;

        public ConnectionToServer(ILog inLogger, string hostIP, int hostPort)
        {
            logger = inLogger;
            Socket socket;
            do
            {
                socket = CreateSocketConnectionToServer(hostIP, hostPort);
            } while (socket == null);

            networkStreamOut = new NetworkStream(socket);
            networkStreamIn = new NetworkStream(socket);
        }

        private Socket CreateSocketConnectionToServer(string serverSite, int hostPort)
        {
            try
            {                
                // Create the socket that hooks into the server
                IPHostEntry serverHost = Dns.GetHostEntry(serverSite);
                IPAddress serverIpAddress = serverHost.AddressList[0];
                IPEndPoint remoteEP = new IPEndPoint(serverIpAddress, hostPort);
                Socket serverSocket = new Socket(serverIpAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                logger.Info($"Trying to connect to : {serverIpAddress.ToString()}");
                serverSocket.Connect(remoteEP);
                logger.Info($"Socket connected to {serverSocket.RemoteEndPoint.ToString()}");
                return serverSocket;
            }
            catch (Exception exception)
            {
                logger.Error(exception.Message);
            }

            logger.Warn($"Returning a null socket from CreateSocketConnectionToServer");
            return null;
        }
                
        public string Receive()
        {
            byte[] bytesFrom = new byte[2048];
            networkStreamIn.Read(bytesFrom); // todo just changed this better chek to make sure it works
            string dataFromServer = Encoding.Default.GetString(bytesFrom).Replace("\0", string.Empty).Trim(); ;
            logger.Info($">> From Server: {dataFromServer}");
            return dataFromServer;
        }
        public void Send(string data)
        {
            byte[] sendBytes = Encoding.Default.GetBytes(data);
            networkStreamOut.Write(sendBytes, 0, sendBytes.Length);
            logger.Info($"<< To Server: {data}");
        }
    }
}
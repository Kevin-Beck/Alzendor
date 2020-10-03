using Alzendor.Core.Utilities.Logger;
using Newtonsoft.Json;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace Alzendor.Client
{
    public class ConnectionToServer
    {
        private ILogger logger;
        private Socket sendToServerSocket;
        private Socket receiveFromServerSocket;
        private int receivePort;
        private string clientName;

        public string DataToSend { get; set; } = "";

        public ConnectionToServer(ILogger inLogger, string charName, string hostIP, string myIP, int hostPort)
        {
            logger = inLogger;
            receivePort = hostPort + 1;
            clientName = charName;
            Thread createReceive = new Thread(CreateReceiveConnectionToServer);
            createReceive.Start();

            CreateSendConnectionToServer(hostIP, hostPort);           
            Thread sendThread = new Thread(SendLoop);
            sendThread.Start();
        }

        private void CreateSendConnectionToServer(string serverSite, int hostPort)
        {
            try
            {
                // Create the socket that hooks into the server
                IPHostEntry serverHost = Dns.GetHostEntry(serverSite);
                IPAddress serverIpAddress = serverHost.AddressList[0];
                IPEndPoint remoteEP = new IPEndPoint(serverIpAddress, hostPort);
                sendToServerSocket = new Socket(serverIpAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                logger.Log(LogLevel.Info, $"Trying to connect to : {serverIpAddress.ToString()}");
                sendToServerSocket.Connect(remoteEP);
                logger.Log(LogLevel.Info, $"Socket connected to {sendToServerSocket.RemoteEndPoint.ToString()}");
                DataToSend = clientName;
            }
            catch (Exception exception)
            {
                logger.Log(LogLevel.Error, exception.Message);
            }
        }
        private void CreateReceiveConnectionToServer()
        {
            // Create open listener for the server to connect to

            try
            {
                // TODO unhardcode the 110001
                IPHostEntry host = Dns.GetHostEntry("localhost");
                IPAddress ipAddress = host.AddressList[0];
                IPEndPoint localEndPoint = new IPEndPoint(ipAddress, 11001);
                receiveFromServerSocket = new Socket(ipAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                receiveFromServerSocket.Bind(localEndPoint);
                receiveFromServerSocket.Listen(10);
                receiveFromServerSocket = receiveFromServerSocket.Accept();
                logger.Log(LogLevel.Info, "Client has recieved connection on its receiver");

                Thread receiveThread = new Thread(ReceiveLoop);
                receiveThread.Start();
            }
            catch(Exception e)
            {
                logger.Log(LogLevel.Error, $"Client Error: CreateReceiveConnectionToServer\n\nMessage:\n{e.Message}\n\nTrace:\n{e.StackTrace}\n\n");
                
            }
        }

        public void ReceiveLoop()
        {
            bool connected = true;
            NetworkStream stream = new NetworkStream(receiveFromServerSocket);
            while (connected)
            {
                try
                {
                    var receivedText = Receive(stream);

                    // todo process the data from the server
                }
                catch (SocketException)
                {
                    logger.Log(LogLevel.Info, $"Server has disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    logger.Log(LogLevel.Error, $"ConnectionToServer: {exception.Message}");
                    connected = false;
                }
            }
        }
        public void SendLoop()
        {
            bool connected = true;
            NetworkStream stream = new NetworkStream(sendToServerSocket);
            while (connected)
            {
                if(DataToSend.Trim() != null && DataToSend.Trim() != "")
                {
                    Send(stream, DataToSend);
                }
            }
        }
        private string Receive(NetworkStream networkStream)
        {
            byte[] bytesFrom = new byte[1024];
            networkStream.Read(bytesFrom); // todo just changed this better chek to make sure it works
            string dataFromServer = Encoding.ASCII.GetString(bytesFrom);
            logger.Log(LogLevel.Info, $"<< From Server: {dataFromServer}");
            return dataFromServer;
        }
        private void Send(NetworkStream networkStream, string data)
        {
            byte[] sendBytes = Encoding.ASCII.GetBytes(data);
            networkStream.Write(sendBytes, 0, sendBytes.Length);
            logger.Log(LogLevel.Info, $">> To Server: {data}");
            DataToSend = "";
        }
    }
}

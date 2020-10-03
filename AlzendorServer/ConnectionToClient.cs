using Alzendor.Core.Utilities.Actions;
using Alzendor.Core.Utilities.Logger;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace Alzendor.Server
{

    public class ConnectionToClient
    {
        private readonly ILogger logger;
        private Socket sendToClientSocket;
        public Socket receiveFromClientSocket;
        string clientID = "unknown ID";
        string clientIP = "unknown IP";

        public string DataToSend { get; set; }

        public ConnectionToClient(ILogger inlogger)
        {
            logger = inlogger;
        }
        public void StartClient(Socket inClientSocket)
        {
            DataToSend = "";
            receiveFromClientSocket = inClientSocket; 
            Thread receiveThread = new Thread(ReceiveLoop);
            receiveThread.Start();
            CreateSendConnectionToServer(inClientSocket.RemoteEndPoint as IPEndPoint);

            for (int i = 0; i < 10; i++)
            {
                Thread.Sleep(2000);
                DataToSend = $"Server Msg ({i})";
            }

        }
        private void CreateSendConnectionToServer(IPEndPoint endPoint)
        {
            try
            {
                // Create the socket that hooks back into the client
                IPHostEntry serverHost = Dns.GetHostEntry(endPoint.Address);
                IPAddress serverIpAddress = serverHost.AddressList[0];
                IPEndPoint remoteEP = new IPEndPoint(endPoint.Address, 11001);
                sendToClientSocket = new Socket(serverIpAddress.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                
                
                logger.Log(LogLevel.Info, $"Trying to connect to : {serverIpAddress.ToString()}");
                sendToClientSocket.Connect(remoteEP);
                logger.Log(LogLevel.Info, $"Socket connected to {sendToClientSocket.RemoteEndPoint.ToString()}");
                Thread sendThread = new Thread(SendLoop);
                sendThread.Start();
            }
            catch (Exception exception)
            {
                logger.Log(LogLevel.Error, exception.Message);
            }
        }
        public void SendLoop()
        {
            bool connected = true;
            NetworkStream stream = new NetworkStream(sendToClientSocket);
            while (connected)
            {
                if (DataToSend.Trim() != null && DataToSend.Trim() != "")
                {
                    Send(stream, DataToSend);
                }
            }
        }
        private void ReceiveLoop()
        {            
            bool connected = true;
            NetworkStream stream = new NetworkStream(receiveFromClientSocket);
            clientID = Receive(stream);

            Console.WriteLine("Server has: " + clientID);
            while (connected)
            {
                try
                {
                    var receivedText = Receive(stream);
                }
                catch (SocketException)
                {
                    logger.Log(LogLevel.Info, $">> client({clientID}) disconnected");
                    connected = false;
                }
                catch (Exception exception)
                {
                    logger.Log(LogLevel.Error, $">> client({clientID}) ERROR: {exception.Message}");
                    connected = false;
                }
            }
        }
        private string Receive(NetworkStream networkStream)
        {
            byte[] bytesFrom = new byte[1024];
            networkStream.Read(bytesFrom);
            string dataFromClient = Encoding.ASCII.GetString(bytesFrom);
            logger.Log(LogLevel.Info, $"<< From client {clientID}: {dataFromClient}");
            return dataFromClient;
        }
        private void Send(NetworkStream networkStream, string data){ 
            byte[] sendBytes = Encoding.ASCII.GetBytes(data);
            networkStream.Write(sendBytes, 0, sendBytes.Length);
            logger.Log(LogLevel.Info, $">> To client {clientID}: {data}");
            DataToSend = "";
        }
    }
}

using Core.Utilities;
using log4net;
using Server.Base;
using Server.DataTransfer;
using Server.Elements;
using StackExchange.Redis;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;

namespace Server.Database
{
    public class RedisImplementation : IDatabaseWrapper
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private IDatabase database;
        private ISubscriber subscriber;

        public RedisImplementation(IDatabase db, ISubscriber sub)
        {
            database = db;
            subscriber = sub;
        }
        public string GetNamingConvention(ElementType type, string elementName)
        {
            return $"{type}:{elementName}";
        }
        public long SendMessageToChannelFromSender(string sender, string receiver, string message)
        {
            return database.Publish(GetNamingConvention(ElementType.CHANNEL, receiver), Objectifier.Stringify(new ChatData(sender, receiver, message)));
        }
        public long SendServerMessageToChannel(ServerMessageType messageType, string channelName, string message)
        {
            return database.Publish(GetNamingConvention(ElementType.CHANNEL, channelName), Objectifier.Stringify(new ChatData(messageType.ToString(), channelName, message)));
        }
        public bool GetElementFromDatabase<T>(string name, ElementType type, out T element)
        {
            element = default;
            if (database.KeyExists(GetNamingConvention(type, name)))
            {
                try
                {
                    element = Objectifier.DeStringify<T>(database.StringGet(GetNamingConvention(type, name)));
                    return true;
                }
                catch (Exception e)
                {
                    logger.Warn("Object could not be cast into requested element" + e.ToString());
                }
            }
            else
            {
                logger.Warn($"No key exists in the database for {GetNamingConvention(type, name)}");
            }
            return false;
        }

        public bool AddElementToDatabase<T>(GameElement element)
        {
            return database.StringSet(GetNamingConvention(element.elementType, element.elementName), Objectifier.Stringify(element));
        }

        public void Subscribe<T>(GameElement element, ConnectionToClient connectionToClient)
        {
            subscriber.Subscribe(GetNamingConvention(element.elementType, element.elementName), (channel, message) =>
            {
                connectionToClient.Send(new ChatData(channel, connectionToClient.ClientID, message));
            });
        }
    }
}

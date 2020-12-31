using log4net;
using Server.Base;
using Server.Database;
using Server.DataTransfer;
using Server.Elements;
using System.Reflection;

namespace Server.Actions
{
    public class SubscribeAction : ActionObject
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);

        public SubscribeAction(string sender, ElementType gameElementType, string elementName) : base(sender, ActionType.SUBSCRIBE, gameElementType, elementName, ActionPriority.LOW)
        {
            
        }

        public override void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection)
        {
            logger.Info($"{Sender} subscribing to element of type: {ElementType} and name {ElementName}");
            if (ElementType == ElementType.CHANNEL)
            {
                if (storage.GetElementFromDatabase(ElementName, ElementType, out ChannelElement channel))
                {
                    logger.Info($"Retrieved Channel: {channel.ChannelName} from database");
                    if (channel.subscribers.Contains(Sender))
                    {
                        logger.Info($"{Sender} is subscribed already? {channel.subscribers.Contains(Sender)}");
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, "You're already subscribed to that channel");
                        return;
                    }
                    else if (!channel.IsPrivate || Sender == ElementName) // the channel is public, or you're subscribing to your own initial channel
                    {
                        logger.Info($"{Sender} is allowed to subscribe to {channel.ChannelName}");
                        channel.AddSubscriber(Sender);

                        storage.Subscribe<ChannelElement>(channel, connection);

                        logger.Info($"{Sender} successfully subscribed");
                        storage.SendServerMessageToChannel(ServerMessageType.Info, ElementName, $"{Sender} has joined {ElementName}");
                    }
                    else
                    {
                        logger.Info($"{Sender} is not permitted to subscribe to {ElementType} + {ElementName}");
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, $"You are not permitted to subscribe to {ElementType} {ElementName}");
                    }
                }
                else
                {
                    logger.Debug($"Could not subscribe to {ElementType} {ElementName} as it was not retreived from database");
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, $"There is no channel to subscribe to with the name {ElementName}, perhaps you want to CREATE it");
                }
            }
        }
    }
}

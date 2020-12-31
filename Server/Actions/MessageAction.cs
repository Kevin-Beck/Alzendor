using log4net;
using Server.Base;
using Server.Database;
using Server.DataTransfer;
using Server.Elements;
using System.Reflection;

namespace Server.Actions
{
    public class MessageAction : ActionObject
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        public string Message { get; set; }

        public MessageAction(string sender, string receiver, string message) : base(sender, ActionType.MESSAGE, ElementType.CHANNEL, receiver, ActionPriority.LOW)
        {
            Message = message;
        }

        public override void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection)
        {
            var targetName = storage.GetNamingConvention(ElementType, ElementName);
            storage.GetElementFromDatabase<ChannelElement>(ElementName, ElementType, out ChannelElement channel);
            if (channel != null)
            {
                if (channel.subscribers.Contains(Sender))
                {
                    logger.Info($"Message permitted: {Sender}");
                    if (storage.SendMessageToChannelFromSender(Sender, ElementName, Message) != 0)
                    {
                        logger.Info($"{Sender} successfully sent message to {ElementName}");
                    }
                    else
                    {
                        logger.Warn($"{Sender} tried to send message to {ElementName} but no one was found by that name");
                    }
                }
                else
                {
                    logger.Info($"{Sender}'s message is not permitted, sender not in subscribers for target, or target is not online");
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, "Sorry, theres nothing to tell by that name.");
                }
            }
            else
            {
                storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, "Sorry, theres nothing to tell by that name.");
            }
        }
    }
}

using log4net;
using Server.Base;
using Server.Database;
using Server.DataTransfer;
using Server.Elements;
using System.Reflection;

namespace Server.Actions
{
    public class CreateAction : ActionObject
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);

        public CreateAction(string sender, ElementType typeOfElement, string nameOfObject) : base(sender, ActionType.CREATE, typeOfElement, nameOfObject, ActionPriority.LOW)
        {

        }

        public override void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection)
        {
            logger.Info($"{Sender} wants to create {ElementType} with name '{ElementName}'");
            if (ElementType == ElementType.CHANNEL)
            {
                if (storage.GetElementFromDatabase(ElementName, ElementType, out ChannelElement foundChannel))
                {
                    logger.Info("Channel Creation failed -> Already a channel with that name");
                    storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, "That channel already exists!");
                }
                else
                {
                    ChannelElement channel = new ChannelElement(ElementName, Sender, false);
                    storage.AddElementToDatabase<ChannelElement>(channel);
                    logger.Info($"The {ElementName} channel has been created successfully by {Sender}");
                    storage.SendServerMessageToChannel(ServerMessageType.Info, Sender, $"The {ElementName} channel has been created successfully!");
                    var subscribeAction = new SubscribeAction(Sender, ElementType.CHANNEL, ElementName);
                    subscribeAction.ExecuteAction(storage, connection);
                    if (ElementName == Sender)
                    {
                        channel.IsPrivate = true;
                        channel.ChannelOwner = "admin";
                        storage.AddElementToDatabase<ChannelElement>(channel);
                    }
                }
            }
            else if (ElementType == ElementType.PLAYER)
            {

            }
        }
    }
}

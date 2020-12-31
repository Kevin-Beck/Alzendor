using log4net;
using Server.Base;
using Server.Database;
using Server.DataTransfer;
using Server.Elements;
using System.Reflection;

namespace Server.Actions
{
    public class ChangeAction : ActionObject
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        public string ElementProperty { get; set; }
        public string NewElementPropertyValue { get; set; }

        /// <summary>
        /// The change object holds the data for the Action of changing the property of a game object to the desired value
        /// </summary>
        /// <param name="sender">The string name of the sender of this action. The name of the thing performing the action</param>
        /// <param name="elementType">The type of GameElement we are changing, Channel, Item etc</param>
        /// <param name="elementName">The name of the Specific game element we are changing.</param>
        /// <param name="property">The property of the game element we are changing, "name" for example</param>
        /// <param name="newPropertyValue">The new property value we are setting the property to.</param>
        /// <example>This shows the change object created for Alice changing the channel name of "DragonTalk" to "DragonSpot"
        /// <code>
        /// var myChange = new ChangeAction("Alice", ElementType.CHANNEL, "DragonTalk", "name", "DragonSpot")
        /// </code>
        /// </example>
        public ChangeAction(string sender, ElementType elementType, string elementName, string property, string newPropertyValue) : base(sender, ActionType.CHANGE, elementType, elementName, ActionPriority.LOW)
        {
            ElementProperty = property;
            NewElementPropertyValue = newPropertyValue;
        }

        public override void ExecuteAction(IDatabaseWrapper storage, ConnectionToClient connection)
        {
            logger.Info($"{Sender} is trying to change {ElementType} {ElementName}'s property {ElementProperty} to {NewElementPropertyValue}");
            if (ElementType == ElementType.CHANNEL)
            {
                if (storage.GetElementFromDatabase(ElementName, ElementType, out ChannelElement channel))
                {
                    logger.Info($"Channel '{ElementName}' has been found in database. Preparing to change property.");
                    if (channel.ChannelOwner != Sender)
                    {
                        storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, $"You cannot change the channel's name as you are not the owner");
                        return;
                    }
                    if (ElementProperty == "privacy")
                    {
                        if (NewElementPropertyValue == "public")
                        {
                            channel.IsPrivate = false;
                            storage.SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to public.");
                            storage.AddElementToDatabase<ChannelElement>(channel);
                        }
                        else if (NewElementPropertyValue == "private")
                        {
                            channel.IsPrivate = true;
                            storage.SendServerMessageToChannel(ServerMessageType.Info, channel.ChannelName, $"{channel.ChannelName} has been set to private.");
                            storage.AddElementToDatabase<ChannelElement>(channel);
                        }
                        else
                        {
                            storage.SendServerMessageToChannel(ServerMessageType.Warning, Sender, $"Unrecognized privacy setting: {NewElementPropertyValue}");
                        }
                    }
                }
            }
        }
    }
}

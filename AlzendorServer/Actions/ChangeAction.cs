using AlzendorServer.Elements;

namespace AlzendorServer.Actions
{
    public class ChangeAction : ActionObject
    {
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
    }
}

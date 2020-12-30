using Server.Elements;

namespace Server.Actions
{
    public class SubscribeAction : ActionObject
    {
        public SubscribeAction(string sender, ElementType gameElementType, string elementName) : base(sender, ActionType.SUBSCRIBE, gameElementType, elementName, ActionPriority.LOW)
        {
            
        }
    }
}

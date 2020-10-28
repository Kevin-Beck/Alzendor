using AlzendorServer.Elements;

namespace AlzendorServer.Actions
{
    public class SubscribeAction : ActionObject
    {
        public SubscribeAction(string sender, ElementType gameElementType, string elementName) : base(sender, ActionType.SUBSCRIBE, gameElementType, elementName, ActionPriority.LOW)
        {
            
        }
    }
}

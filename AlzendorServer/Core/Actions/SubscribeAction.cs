using AlzendorServer.Core.Elements;

namespace AlzendorServer.Core.Actions
{
    public class SubscribeAction : ActionObject
    {
        public SubscribeAction(string sender, ElementType gameElementType, string elementName) : base(sender, ActionType.SUBSCRIBE, gameElementType, elementName, ActionPriority.LOW)
        {
            
        }
    }
}

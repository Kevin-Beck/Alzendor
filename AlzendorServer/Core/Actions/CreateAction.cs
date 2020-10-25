using AlzendorServer.Core.Elements;

namespace AlzendorServer.Core.Actions
{
    public class CreateAction : ActionObject
    {
        public CreateAction(string sender, ElementType typeOfElement, string nameOfObject) : base(sender, ActionType.CREATE, typeOfElement, nameOfObject, ActionPriority.LOW)
        {

        }
    }
}
